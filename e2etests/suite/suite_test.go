// SPDX-License-Identifier:Apache-2.0

package e2e

import (
	"context"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/openperouter/openperouter/e2etests/pkg/config"
	"github.com/openperouter/openperouter/e2etests/pkg/executor"
	"github.com/openperouter/openperouter/e2etests/pkg/frrk8s"
	"github.com/openperouter/openperouter/e2etests/pkg/infra"
	"github.com/openperouter/openperouter/e2etests/pkg/k8s"
	"github.com/openperouter/openperouter/e2etests/pkg/k8sclient"
	"github.com/openperouter/openperouter/e2etests/pkg/openperouter"
	"github.com/openperouter/openperouter/e2etests/tests"
	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	clientset "k8s.io/client-go/kubernetes"
	"sigs.k8s.io/controller-runtime/pkg/log"
	"sigs.k8s.io/controller-runtime/pkg/log/zap"
)

var (
	updater         *config.Updater
	infraConfigPath string
)

func handleFlags() {
	flag.StringVar(&executor.Kubectl, "kubectl", "kubectl", "the path for the kubectl binary")
	flag.StringVar(&tests.ValidatorPath, "hostvalidator", "hostvalidator", "the path for the hostvalidator binary")
	flag.StringVar(&tests.ReportPath, "reporterpath", "/tmp", "the path for the reporter")
	flag.BoolVar(&tests.HostMode, "systemdmode", false, "tells if openperouter is running on the host")
	flag.BoolVar(&tests.SkipUnderlayPassthrough, "skip-underlay-passthrough", false, "skip creating underlay in passthrough tests")
	flag.StringVar(&infraConfigPath, "infra-config", "e2etests/infra/topology-default.json", "path to topology config JSON")
	flag.StringVar(&frrk8s.Namespace, "frrk8s-namespace", frrk8s.Namespace, "namespace where FRR-K8s pods run")
	flag.Parse()
}

func TestMain(m *testing.M) {
	handleFlags()
	if testing.Short() {
		return
	}

	os.Exit(m.Run())
}

func TestE2E(t *testing.T) {
	if testing.Short() {
		return
	}

	RegisterFailHandler(ginkgo.Fail)
	ginkgo.RunSpecs(t, "E2E Suite")
}

var _ = ginkgo.BeforeSuite(func() {
	log.SetLogger(zap.New(zap.WriteTo(ginkgo.GinkgoWriter), zap.UseDevMode(true)))
	clientconfig, err := k8sclient.RestConfig()
	Expect(err).NotTo(HaveOccurred(), "failed to load kubeconfig (KUBECONFIG=%s)", os.Getenv("KUBECONFIG"))
	updater, err = config.UpdaterForCRs(clientconfig, openperouter.Namespace)
	Expect(err).NotTo(HaveOccurred())
	tests.Updater = updater
	kubeconfig := os.Getenv("KUBECONFIG")
	if kubeconfig == "" {
		kubeconfig = filepath.Join(os.Getenv("HOME"), ".kube", "config")
	}
	reporter, err := k8s.InitReporter(kubeconfig, tests.ReportPath, openperouter.Namespace, frrk8s.Namespace)
	Expect(err).NotTo(HaveOccurred(), "failed to initialize k8s reporter (kubeconfig=%s)", kubeconfig)
	tests.K8sReporter = reporter

	cs := k8sclient.New()
	deployNodeExecHelper(cs)

	ginkgo.By("Loading topology config from " + infraConfigPath)
	cfg, err := infra.LoadTopologyConfig(infraConfigPath)
	Expect(err).NotTo(HaveOccurred(), "failed to load topology config")
	infra.ApplyTopologyConfig(cfg)
})

const nodeExecHelperName = "node-exec-helper"

func deployNodeExecHelper(cs clientset.Interface) {
	ginkgo.By("Deploying node-exec-helper DaemonSet")
	ds := &appsv1.DaemonSet{
		ObjectMeta: metav1.ObjectMeta{
			Name:      nodeExecHelperName,
			Namespace: openperouter.Namespace,
		},
		Spec: appsv1.DaemonSetSpec{
			Selector: &metav1.LabelSelector{
				MatchLabels: map[string]string{"app": nodeExecHelperName},
			},
			Template: corev1.PodTemplateSpec{
				ObjectMeta: metav1.ObjectMeta{
					Labels: map[string]string{"app": nodeExecHelperName},
				},
				Spec: corev1.PodSpec{
					ServiceAccountName: "controller",
					HostPID:            true,
					HostNetwork:        true,
					Tolerations:        []corev1.Toleration{{Operator: corev1.TolerationOpExists}},
					Containers: []corev1.Container{{
						Name:    "nsenter",
						Image:   "registry.access.redhat.com/ubi9/ubi:latest",
						// ubi9/ubi includes util-linux which provides nsenter
						Command: []string{"sleep", "infinity"},
						SecurityContext: &corev1.SecurityContext{
							Privileged: new(true),
						},
					}},
				},
			},
		},
	}

	_, err := cs.AppsV1().DaemonSets(openperouter.Namespace).Create(context.Background(), ds, metav1.CreateOptions{})
	if apierrors.IsAlreadyExists(err) {
		err = nil
	}
	Expect(err).NotTo(HaveOccurred())

	ginkgo.By("Waiting for node-exec-helper pods to be ready")
	Eventually(func() error {
		d, err := cs.AppsV1().DaemonSets(openperouter.Namespace).Get(context.Background(), nodeExecHelperName, metav1.GetOptions{})
		if err != nil {
			return err
		}
		if d.Status.DesiredNumberScheduled == 0 {
			return fmt.Errorf("node-exec-helper: no pods scheduled yet")
		}
		if d.Status.NumberReady < d.Status.DesiredNumberScheduled {
			return fmt.Errorf("node-exec-helper: %d/%d ready", d.Status.NumberReady, d.Status.DesiredNumberScheduled)
		}
		return nil
	}, 3*time.Minute, 2*time.Second).Should(Succeed())

	ginkgo.By("Verifying node-exec-helper pods exist on all nodes")
	Eventually(func() error {
		pods, err := cs.CoreV1().Pods(openperouter.Namespace).List(
			context.Background(),
			metav1.ListOptions{LabelSelector: "app=" + nodeExecHelperName},
		)
		if err != nil {
			return err
		}
		nodes, err := cs.CoreV1().Nodes().List(context.Background(), metav1.ListOptions{})
		if err != nil {
			return err
		}
		covered := make(map[string]bool)
		for i := range pods.Items {
			covered[pods.Items[i].Spec.NodeName] = true
		}
		for _, node := range nodes.Items {
			if !covered[node.Name] {
				return fmt.Errorf("no helper pod on node %s", node.Name)
			}
		}
		return nil
	}, 30*time.Second, 2*time.Second).Should(Succeed())

	executor.InitForNode(cs, openperouter.Namespace, "app="+nodeExecHelperName)
}

func deleteNodeExecHelper(cs clientset.Interface) {
	ginkgo.By("Deleting node-exec-helper DaemonSet")
	err := cs.AppsV1().DaemonSets(openperouter.Namespace).Delete(context.Background(), nodeExecHelperName, metav1.DeleteOptions{})
	if apierrors.IsNotFound(err) {
		return
	}
	Expect(err).NotTo(HaveOccurred())
}

var _ = ginkgo.AfterSuite(func() {
	deleteNodeExecHelper(k8sclient.New())

	if updater == nil {
		return
	}
	err := updater.CleanAll()
	Expect(err).NotTo(HaveOccurred())
})
