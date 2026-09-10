export interface ReadHelmDeploymentStateOptions {
  checkoutPath: string;
  environment: string;
  chartName: string;
  dependency: string;
  wrapperChartPath: string;
}

export interface HelmDeploymentState {
  dependencyVersion: string;
  imageTag: string;
  chartSourceRef: string;
}
