export interface NetworkConfig {
  readonly cidr: string;
  readonly maxAzs: number;
  readonly natGateways: number;
}

export interface StorageConfig {
  readonly inputExpirationDays: number;
  readonly workdirExpirationDays: number;
  readonly restrictToJobRole: boolean;
  readonly additionalPrincipalArns: readonly string[];
}

export interface RegistryConfig {
  readonly untaggedImageExpirationDays: number;
}

export interface QueueConfig {
  readonly name: string;
  readonly instanceTypes: readonly string[];
  readonly gpu: boolean;
  readonly spotMaxvCpus: number;
  readonly onDemandMaxvCpus: number;
  readonly spotBidPercentage?: number;
  readonly volumeSizeGb: number;
  readonly volumeThroughputMibps: number;
  readonly volumeIops: number;
}

export interface BatchConfig {
  readonly cpuSmall: QueueConfig;
  readonly gpuStandard: QueueConfig;
  readonly gpuHighmem: QueueConfig;
}

export interface Config {
  readonly project: string;
  readonly team: string;
  readonly gitRepository: string;
  readonly network: NetworkConfig;
  readonly storage: StorageConfig;
  readonly registry: RegistryConfig;
  readonly batch: BatchConfig;
}

export const config: Config = {
  project: "nvidia-nims",
  team: "loka-labs",
  gitRepository: "loka-labs-nvidia-nims-nextflow",

  network: {
    cidr: "10.60.0.0/16",
    maxAzs: 2,
    natGateways: 1,
  },

  storage: {
    inputExpirationDays: 30,
    workdirExpirationDays: 30,
    restrictToJobRole: true,
    additionalPrincipalArns: ["arn:aws:iam::520168724997:role/aws-reserved/sso.amazonaws.com/*"],
  },

  registry: {
    untaggedImageExpirationDays: 14,
  },

  batch: {
    cpuSmall: {
      name: "cpu-small",
      instanceTypes: ["m5.large", "m5.xlarge", "m5.2xlarge", "c5.large", "c5.xlarge", "c5.2xlarge"],
      gpu: false,
      spotMaxvCpus: 128,
      onDemandMaxvCpus: 32,
      volumeSizeGb: 100,
      volumeThroughputMibps: 250,
      volumeIops: 3000,
    },
    gpuStandard: {
      name: "gpu-standard",
      instanceTypes: ["g6e.2xlarge", "g6e.4xlarge", "g6e.8xlarge"],
      gpu: true,
      spotMaxvCpus: 128,
      onDemandMaxvCpus: 32,
      volumeSizeGb: 200,
      volumeThroughputMibps: 500,
      volumeIops: 6000,
    },
    gpuHighmem: {
      name: "gpu-highmem",
      instanceTypes: ["g6e.12xlarge", "p4d.24xlarge"],
      gpu: true,
      spotMaxvCpus: 192,
      onDemandMaxvCpus: 96,
      volumeSizeGb: 1400,
      volumeThroughputMibps: 1000,
      volumeIops: 16000,
    },
  },
};
