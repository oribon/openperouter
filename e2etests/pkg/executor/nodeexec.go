// SPDX-License-Identifier:Apache-2.0

package executor

import (
	"context"
	"errors"
	"fmt"
	"os/exec"
	"time"

	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/util/wait"
	clientset "k8s.io/client-go/kubernetes"
)

const (
	nodeExecHelperName  = "node-exec-helper"
	nodeExecHelperLabel = "app=" + nodeExecHelperName
)

var (
	forNodeClient    clientset.Interface
	forNodeNamespace string
)

func SetupNodeExec(cs clientset.Interface, namespace string) error {
	ds := &appsv1.DaemonSet{
		ObjectMeta: metav1.ObjectMeta{
			Name:      nodeExecHelperName,
			Namespace: namespace,
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
						Image:   "busybox:1.36",
						Command: []string{"sleep", "infinity"},
						SecurityContext: &corev1.SecurityContext{
							Privileged: new(true),
						},
					}},
				},
			},
		},
	}

	_, err := cs.AppsV1().DaemonSets(namespace).Create(context.Background(), ds, metav1.CreateOptions{})
	if err != nil && !apierrors.IsAlreadyExists(err) {
		return fmt.Errorf("creating node-exec-helper DaemonSet: %w", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
	defer cancel()

	err = wait.PollUntilContextCancel(ctx, 2*time.Second, true, func(ctx context.Context) (bool, error) {
		d, err := cs.AppsV1().DaemonSets(namespace).Get(ctx, nodeExecHelperName, metav1.GetOptions{})
		if err != nil {
			return false, nil
		}
		if d.Status.DesiredNumberScheduled == 0 {
			return false, nil
		}
		return d.Status.NumberReady >= d.Status.DesiredNumberScheduled, nil
	})
	if err != nil {
		return fmt.Errorf("waiting for node-exec-helper pods to be ready: %w", err)
	}

	forNodeClient = cs
	forNodeNamespace = namespace
	return nil
}

func TeardownNodeExec() error {
	if forNodeClient == nil {
		return nil
	}
	err := forNodeClient.AppsV1().DaemonSets(forNodeNamespace).Delete(
		context.Background(), nodeExecHelperName, metav1.DeleteOptions{})
	if apierrors.IsNotFound(err) {
		return nil
	}
	return err
}

func ForNode(nodeName string) (Executor, error) {
	pods, err := forNodeClient.CoreV1().Pods(forNodeNamespace).List(
		context.Background(),
		metav1.ListOptions{LabelSelector: nodeExecHelperLabel},
	)
	if err != nil {
		return nil, fmt.Errorf("failed to list helper pods: %w", err)
	}
	for i := range pods.Items {
		if pods.Items[i].Spec.NodeName == nodeName {
			return &nodeExecutor{namespace: forNodeNamespace, podName: pods.Items[i].Name}, nil
		}
	}
	return nil, fmt.Errorf("no node-exec-helper pod found on node %s", nodeName)
}

type nodeExecutor struct {
	namespace string
	podName   string
}

func (e *nodeExecutor) Exec(cmd string, args ...string) (string, error) {
	if Kubectl == "" {
		return "", errors.New("the kubectl parameter is not set")
	}
	nsenterArgs := []string{"exec", e.podName, "-n", e.namespace, "-c", "nsenter", "--",
		"chroot", "/proc/1/root", "nsenter", "-t", "1", "-m", "-u", "-i", "-n", cmd}
	fullargs := append(nsenterArgs, args...)
	out, err := exec.Command(Kubectl, fullargs...).CombinedOutput()
	if err != nil {
		return string(out), fmt.Errorf("exec on node via pod %s/%s failed: %w. Output: %s",
			e.namespace, e.podName, err, string(out))
	}
	return string(out), nil
}
