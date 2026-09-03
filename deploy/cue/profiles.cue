package chronicledeploy

#HostProfile: {
  vcpu:      int & >0
  memoryGiB: int & >0
}

#ResourceCeiling: {
  cpuMilli:  int & >=0
  memoryMiB: int & >0
}

#KubernetesDeploymentProfile: {
  name:        #DeploymentProfile
  overlay:     string
  host:        #HostProfile
  description: string

  observability: {
    colocated: bool
    backends:  [...#ObservabilityBackend]
    retentionDays: int & >=0
  }

  backend: {
    // Authorization state is cached in-process. The deployed Hazelcast
    // configuration is not yet a cross-pod coherence mechanism.
    replicas:   1
    heapMaxMiB: int & >0
    request:    #ResourceCeiling
    limit:      #ResourceCeiling
  }

  frontend: {
    replicas: int & >=1
  }

  postgres: {
    primaryOnly: bool
    request:     #ResourceCeiling
    limit:       #ResourceCeiling
  }

  namespaceQuota: {
    requestCpuMilli:  int & >0
    requestMemoryMiB: int & >0
    limitCpuMilli:    int & >0
    limitMemoryMiB:   int & >0
    pods:             int & >0
  }

  if host.memoryGiB <= 8 {
    observability: {
      colocated: false
      retentionDays: 0
    }
    backend: {
      replicas:   1
      heapMaxMiB: <=2048
    }
    frontend: replicas: 1
    postgres: primaryOnly: true
    namespaceQuota: limitMemoryMiB: <=6144
  }
}

kubernetesProfiles: {
  rhel9Small: #KubernetesDeploymentProfile & {
    name:        "k8s_rhel9_small"
    overlay:     "k8s/overlays/rhel9-small"
    description: "Constrained single-node RHEL 9 profile for 4 vCPU / 8 GB."
    host: {
      vcpu:      4
      memoryGiB: 8
    }
    observability: {
      colocated: false
      backends: [
        "external_institutional",
      ]
      retentionDays: 0
    }
    backend: {
      replicas:   1
      heapMaxMiB: 2048
      request: {
        cpuMilli:  500
        memoryMiB: 1536
      }
      limit: {
        cpuMilli:  2000
        memoryMiB: 3072
      }
    }
    frontend: replicas: 1
    postgres: {
      primaryOnly: true
      request: {
        cpuMilli:  250
        memoryMiB: 1024
      }
      limit: {
        cpuMilli:  2000
        memoryMiB: 2048
      }
    }
    namespaceQuota: {
      requestCpuMilli:  1500
      requestMemoryMiB: 5120
      limitCpuMilli:    5000
      limitMemoryMiB:   6144
      pods:             15
    }
  }

  rhel9Standard: #KubernetesDeploymentProfile & {
    name:        "k8s_rhel9_standard"
    overlay:     "k8s/overlays/production"
    description: "Minimum reasonable single-node RHEL 9 profile for 8 vCPU / 16 GB."
    host: {
      vcpu:      8
      memoryGiB: 16
    }
    observability: {
      colocated: true
      backends: [
        "victoria_metrics",
        "victoria_logs",
      ]
      retentionDays: 14
    }
    backend: {
      replicas:   1
      heapMaxMiB: 3072
      request: {
        cpuMilli:  500
        memoryMiB: 2048
      }
      limit: {
        cpuMilli:  3000
        memoryMiB: 4096
      }
    }
    frontend: replicas: 2
    postgres: {
      primaryOnly: true
      request: {
        cpuMilli:  250
        memoryMiB: 1024
      }
      limit: {
        cpuMilli:  2000
        memoryMiB: 2048
      }
    }
    namespaceQuota: {
      requestCpuMilli:  3000
      requestMemoryMiB: 5120
      limitCpuMilli:    8000
      limitMemoryMiB:   10240
      pods:             30
    }
  }

  rhel9ObservabilityColocated: #KubernetesDeploymentProfile & {
    name:        "k8s_rhel9_observability_colocated"
    overlay:     "k8s/overlays/production"
    description: "Preferred 8 vCPU / 32 GB target when Grafana, VictoriaMetrics, and VictoriaLogs are colocated."
    host: {
      vcpu:      8
      memoryGiB: 32
    }
    observability: {
      colocated: true
      backends: [
        "victoria_metrics",
        "victoria_logs",
      ]
      retentionDays: 30
    }
    backend: {
      replicas:   1
      heapMaxMiB: 3072
      request: {
        cpuMilli:  500
        memoryMiB: 2048
      }
      limit: {
        cpuMilli:  3000
        memoryMiB: 4096
      }
    }
    frontend: replicas: 2
    postgres: {
      primaryOnly: true
      request: {
        cpuMilli:  250
        memoryMiB: 1024
      }
      limit: {
        cpuMilli:  2000
        memoryMiB: 2048
      }
    }
    namespaceQuota: {
      requestCpuMilli:  3000
      requestMemoryMiB: 5120
      limitCpuMilli:    8000
      limitMemoryMiB:   10240
      pods:             30
    }
  }
}

kubernetesProfileExport: kubernetesProfiles
