//go:build ppc64le

/*
 * This file is part of the KubeVirt project
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 * Copyright The KubeVirt Authors.
 *
 */

package util

import (
	"fmt"

	"golang.org/x/sys/unix"
)

// GetPodCPUSet returns the CPUs the virt-launcher process may run on.
//
// On ppc64le the compute container is privileged, so it does not get a private
// cgroup namespace and /sys/fs/cgroup/cpuset.cpus.effective shows the host root
// cgroup (all online CPUs). The scheduler affinity mask always matches the
// CPU Manager allocation.
func GetPodCPUSet() ([]int, error) {
	var mask unix.CPUSet
	if err := unix.SchedGetaffinity(0, &mask); err != nil {
		return nil, fmt.Errorf("failed to get CPU affinity: %v", err)
	}
	var cpus []int
	for i := 0; i < len(mask)*64; i++ {
		if mask.IsSet(i) {
			cpus = append(cpus, i)
		}
	}
	return cpus, nil
}
