// poolwatch — a small Go controller for MetalLB clusters.
//
// It implements, for real, the alert that Lesson 8 could only describe in
// PromQL:
//
//	"A LoadBalancer Service has an address, but no node is announcing it."
//
// That state is invisible to `kubectl get svc` (the EXTERNAL-IP looks perfect)
// and it is exactly what Lesson 4 (no endpoints), Lesson 5 (excluded node) and
// Lesson 7 (serviceSelectors) each produced on purpose.
//
// What it does:
//   * reconciles every Service of type LoadBalancer
//   * looks up MetalLB's ServiceL2Status / ServiceBGPStatus CRs for that Service
//   * exposes metrics: announced / pending / orphaned, plus pool usage ratios
//   * emits a Kubernetes Warning event on a Service that is orphaned
//
// Build and run: see the lesson README.
package main

import (
	"context"
	"flag"
	"fmt"
	"net/http"
	"os"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/builder"
	"sigs.k8s.io/controller-runtime/pkg/cache"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/event"
	"sigs.k8s.io/controller-runtime/pkg/handler"
	"sigs.k8s.io/controller-runtime/pkg/log/zap"
	"sigs.k8s.io/controller-runtime/pkg/metrics/server"
	"sigs.k8s.io/controller-runtime/pkg/predicate"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"

	metallbv1beta1 "go.universe.tf/metallb/api/v1beta1"
)

var (
	// One series per Service and protocol, value 1 when a node is announcing it.
	announced = prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: "poolwatch_service_announced",
		Help: "1 if the Service's load balancer IP is announced by at least one node, per protocol.",
	}, []string{"namespace", "service", "ip", "protocol"})

	// Services that asked for a load balancer and have not been given an address.
	pending = prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: "poolwatch_service_pending",
		Help: "1 if the Service is of type LoadBalancer and has no address assigned.",
	}, []string{"namespace", "service"})

	// Services that have an address nobody announces. This is the alert.
	orphaned = prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: "poolwatch_service_orphaned",
		Help: "1 if the Service holds a load balancer IP that no node announces.",
	}, []string{"namespace", "service", "ip"})

	// How full each IPAddressPool is (0..1).
	poolUsage = prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: "poolwatch_pool_usage_ratio",
		Help: "Fraction of an IPAddressPool's addresses that are currently assigned.",
	}, []string{"pool"})
)

// labels MetalLB puts on the per-Service status CRs (see lesson 3/6).
const (
	labelServiceName      = "metallb.io/service-name"
	labelServiceNamespace = "metallb.io/service-namespace"
	metallbNamespace      = "metallb-system"
)

// ServiceReconciler looks at one Service and decides whether its address is
// actually on the wire.
type ServiceReconciler struct {
	client.Client
	Recorder interface {
		Eventf(object runtime.Object, eventtype, reason, messageFmt string, args ...interface{})
	}
}

func (r *ServiceReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	log := ctrl.LoggerFrom(ctx)

	// Metrics are keyed by namespace/service, so clear this Service's series
	// before recomputing them: reconcile must be idempotent.
	clearSeries(req.Namespace, req.Name)

	var svc corev1.Service
	if err := r.Get(ctx, req.NamespacedName, &svc); err != nil {
		return ctrl.Result{}, client.IgnoreNotFound(err)
	}
	if svc.Spec.Type != corev1.ServiceTypeLoadBalancer {
		return ctrl.Result{}, nil
	}

	// 1. Did the controller give it an address at all?
	ips := loadBalancerIPs(&svc)
	if len(ips) == 0 {
		pending.WithLabelValues(svc.Namespace, svc.Name).Set(1)
		log.Info("service is pending an address", "service", svc.Namespace+"/"+svc.Name)
		return ctrl.Result{}, nil
	}

	// 2. Which nodes are announcing it? MetalLB records this in two CRs that
	//    live in the metallb-system namespace, labelled with the Service.
	selector := client.MatchingLabels{
		labelServiceName:      svc.Name,
		labelServiceNamespace: svc.Namespace,
	}

	protocols := map[string][]string{} // protocol -> nodes

	var l2List metallbv1beta1.ServiceL2StatusList
	if err := r.List(ctx, &l2List, client.InNamespace(metallbNamespace), selector); err != nil {
		return ctrl.Result{}, err
	}
	for _, s := range l2List.Items {
		if s.Status.Node != "" {
			protocols["layer2"] = append(protocols["layer2"], s.Status.Node)
		}
	}

	var bgpList metallbv1beta1.ServiceBGPStatusList
	if err := r.List(ctx, &bgpList, client.InNamespace(metallbNamespace), selector); err != nil {
		return ctrl.Result{}, err
	}
	for _, s := range bgpList.Items {
		if s.Status.Node != "" {
			protocols["bgp"] = append(protocols["bgp"], s.Status.Node)
		}
	}

	// 3. Report.
	announcing := len(protocols) > 0
	for protocol, nodes := range protocols {
		for _, ip := range ips {
			announced.WithLabelValues(svc.Namespace, svc.Name, ip, protocol).Set(1)
		}
		log.V(1).Info("service is announced", "service", svc.Namespace+"/"+svc.Name,
			"protocol", protocol, "nodes", nodes)
	}

	if !announcing {
		for _, ip := range ips {
			orphaned.WithLabelValues(svc.Namespace, svc.Name, ip).Set(1)
		}
		log.Info("ORPHANED: address assigned but nobody announces it",
			"service", svc.Namespace+"/"+svc.Name, "ips", ips,
			"hint", "no ready endpoints, no matching advertisement, or the service is not selected by one")
		r.Recorder.Eventf(&svc, corev1.EventTypeWarning, "NotAnnounced",
			"LoadBalancer IP %v is assigned but no node is announcing it", ips)
	}

	return ctrl.Result{}, nil
}

// SetupWithManager registers the reconciler and the secondary watches.
func (r *ServiceReconciler) SetupWithManager(mgr ctrl.Manager) error {
	// Map a MetalLB status CR back to the Service it describes, so that a change
	// in announcement state re-reconciles the Service immediately.
	statusToService := handler.EnqueueRequestsFromMapFunc(func(_ context.Context, obj client.Object) []reconcile.Request {
		name := obj.GetLabels()[labelServiceName]
		ns := obj.GetLabels()[labelServiceNamespace]
		if name == "" || ns == "" {
			return nil
		}
		return []reconcile.Request{{NamespacedName: types.NamespacedName{Namespace: ns, Name: name}}}
	})

	// Only Services of type LoadBalancer are our business.
	onlyLoadBalancers := predicate.Funcs{
		CreateFunc:  func(e event.CreateEvent) bool { return isLoadBalancer(e.Object) },
		UpdateFunc:  func(e event.UpdateEvent) bool { return isLoadBalancer(e.ObjectNew) },
		DeleteFunc:  func(e event.DeleteEvent) bool { return isLoadBalancer(e.Object) },
		GenericFunc: func(e event.GenericEvent) bool { return isLoadBalancer(e.Object) },
	}

	return ctrl.NewControllerManagedBy(mgr).
		Named("service-announcement").
		For(&corev1.Service{}, builder.WithPredicates(onlyLoadBalancers)).
		Watches(&metallbv1beta1.ServiceL2Status{}, statusToService).
		Watches(&metallbv1beta1.ServiceBGPStatus{}, statusToService).
		Complete(r)
}

// PoolReconciler turns each IPAddressPool's own status into a usage ratio.
type PoolReconciler struct {
	client.Client
}

func (r *PoolReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	var pool metallbv1beta1.IPAddressPool
	if err := r.Get(ctx, req.NamespacedName, &pool); err != nil {
		poolUsage.DeleteLabelValues(req.Name)
		return ctrl.Result{}, client.IgnoreNotFound(err)
	}
	used := pool.Status.AssignedIPv4 + pool.Status.AssignedIPv6
	free := pool.Status.AvailableIPv4 + pool.Status.AvailableIPv6
	total := used + free
	if total == 0 {
		return ctrl.Result{}, nil
	}
	ratio := float64(used) / float64(total)
	poolUsage.WithLabelValues(pool.Name).Set(ratio)
	if ratio > 0.9 {
		ctrl.LoggerFrom(ctx).Info("pool is nearly exhausted",
			"pool", pool.Name, "used", used, "total", total, "ratio", fmt.Sprintf("%.2f", ratio))
	}
	return ctrl.Result{}, nil
}

func (r *PoolReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		Named("pool-usage").
		For(&metallbv1beta1.IPAddressPool{}).
		Complete(r)
}

// ---- helpers ---------------------------------------------------------------

func isLoadBalancer(obj client.Object) bool {
	svc, ok := obj.(*corev1.Service)
	if !ok {
		return false
	}
	return svc.Spec.Type == corev1.ServiceTypeLoadBalancer
}

func loadBalancerIPs(svc *corev1.Service) []string {
	var out []string
	for _, ing := range svc.Status.LoadBalancer.Ingress {
		if ing.IP != "" {
			out = append(out, ing.IP)
		}
	}
	return out
}

func clearSeries(namespace, name string) {
	announced.DeletePartialMatch(prometheus.Labels{"namespace": namespace, "service": name})
	pending.DeletePartialMatch(prometheus.Labels{"namespace": namespace, "service": name})
	orphaned.DeletePartialMatch(prometheus.Labels{"namespace": namespace, "service": name})
}

func main() {
	var metricsAddr string
	var syncPeriod time.Duration
	flag.StringVar(&metricsAddr, "metrics-bind-address", ":9090", "address for the /metrics endpoint")
	flag.DurationVar(&syncPeriod, "sync-period", 30*time.Second, "how often to re-check every Service")
	opts := zap.Options{Development: true}
	opts.BindFlags(flag.CommandLine)
	flag.Parse()

	ctrl.SetLogger(zap.New(zap.UseFlagOptions(&opts)))
	setupLog := ctrl.Log.WithName("setup")

	// Our own metrics endpoint, so the poolwatch_* series are readable without
	// MetalLB's HTTPS+RBAC setup (see lesson 9).
	prometheus.MustRegister(announced, pending, orphaned, poolUsage)
	go func() {
		mux := http.NewServeMux()
		mux.Handle("/metrics", promhttp.Handler())
		mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) { _, _ = w.Write([]byte("ok")) })
		setupLog.Info("serving metrics", "addr", metricsAddr)
		if err := http.ListenAndServe(metricsAddr, mux); err != nil {
			setupLog.Error(err, "metrics server failed")
			os.Exit(1)
		}
	}()

	scheme := runtime.NewScheme()
	if err := clientgoscheme.AddToScheme(scheme); err != nil {
		setupLog.Error(err, "adding client-go scheme")
		os.Exit(1)
	}
	if err := metallbv1beta1.AddToScheme(scheme); err != nil {
		setupLog.Error(err, "adding metallb scheme")
		os.Exit(1)
	}

	mgr, err := ctrl.NewManager(ctrl.GetConfigOrDie(), ctrl.Options{
		Scheme:  scheme,
		Metrics: server.Options{BindAddress: "0"}, // we serve our own
		Cache:   cache.Options{SyncPeriod: &syncPeriod},
	})
	if err != nil {
		setupLog.Error(err, "creating manager")
		os.Exit(1)
	}

	if err := (&ServiceReconciler{
		Client:   mgr.GetClient(),
		Recorder: mgr.GetEventRecorderFor("poolwatch"),
	}).SetupWithManager(mgr); err != nil {
		setupLog.Error(err, "setting up Service reconciler")
		os.Exit(1)
	}
	if err := (&PoolReconciler{Client: mgr.GetClient()}).SetupWithManager(mgr); err != nil {
		setupLog.Error(err, "setting up Pool reconciler")
		os.Exit(1)
	}

	setupLog.Info("starting poolwatch")
	if err := mgr.Start(ctrl.SetupSignalHandler()); err != nil {
		setupLog.Error(err, "manager exited")
		os.Exit(1)
	}
}
