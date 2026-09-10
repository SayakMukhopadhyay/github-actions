export interface PrepareHelmPackageOptions {
  workspace: string;
  workingDirectory: string;
  development: boolean;
  commitSha: string;
  runnerTemp: string;
}

export interface HelmPackagePreparation {
  chartDirectory: string;
  chartName: string;
  chartVersion: string;
  repositoriesFile: string;
}
