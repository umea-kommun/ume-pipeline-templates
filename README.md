# ume-pipeline-templates

Azure DevOps pipeline templates for Umeå kommun Team Turkos projects.

[[_TOC_]]

## Overview

This repository contains reusable Azure DevOps pipeline templates that standardize build, deployment, and release processes across Team Turkos applications. The templates support multiple deployment targets including Azure cloud services and on-premises infrastructure.

## Repository Structure

```
pipelines/
├── azure/              # Azure cloud deployment templates
├── general/            # Shared build and utility templates
├── onprem/             # On-premises deployment templates
└── release/            # Release orchestration and management
utilities/              # PowerShell utility modules
```

## Usage

### Referencing Templates

Reference this repository in your pipeline using the `resources` section:

```yaml
resources:
  repositories:
    - repository: templates
      type: git
      name: Turkos/ume-pipeline-templates
      ref: refs/tags/release/v251014T0947-14671 # Latest release tag (any branch/tag can be referenced)
```

### Example: Building and Deploying a Backend Service

```yaml
stages:
  - stage: BuildBackendStage
    displayName: Build Backend
    jobs:
      - template: pipelines/azure/template-build-backend.yml@templates
        parameters:
          projectFolderName: ume-app-templateservice
          entrypointProjectName: Umea.se.TemplateService.API

  - stage: DeployBackendStage
    displayName: Deploy Backend
    dependsOn: BuildBackendStage
    jobs:
      - template: pipelines/azure/template-deploy-backend.yml@templates
        parameters:
          azureSubscription: $(serviceConnection)
          environment: dev
          resourceGroup: ume-rg-template-dev
          appName: ume-app-templateservice-dev
          projectFolderName: ume-app-templateservice
          pingEndpoints:
            - /api/v1.0/home/ping
```

### Example: Building and Deploying a Frontend Application

```yaml
stages:
  - stage: BuildFrontendStage
    displayName: Build Frontend
    jobs:
      - template: pipelines/azure/template-build-frontend.yml@templates
        parameters:
          environment: dev
          projectFolderName: ume-stapp-template

  - stage: DeployFrontendStage
    displayName: Deploy Frontend
    dependsOn: BuildFrontendStage
    jobs:
      - template: pipelines/azure/template-deploy-frontend.yml@templates
        parameters:
          environment: dev
          projectFolderName: ume-stapp-template
          deploymentToken: $(template-deployment-token)
```

### Example: Infrastructure as Code Pipeline

```yaml
stages:
  - stage: DeployInfrastructureStage
    displayName: Deploy Infrastructure
    jobs:
      - template: pipelines/azure/template-deploy-infrastructure.yml@templates
        parameters:
          environment: dev
          serviceConnection: $(serviceConnection)
          resourceGroup: ume-rg-template-dev
          entrypointScriptPath: iac/entrypoint.ps1
          personalAccessToken: $(System.AccessToken)

  - stage: UpdateKeyVaultStage
    displayName: Update Key Vault
    dependsOn: DeployInfrastructureStage
    jobs:
      - template: pipelines/azure/template-update-keyvault.yml@templates
        parameters:
          environment: dev
          templateRepoAlias: templates
          serviceConnection: $(serviceConnection)
          variableGroupName: ume-rg-template-dev
          keyVaultName: umekvtemplatedev
          personalAccessToken: $(System.AccessToken)
```

## Common Variables

The templates use standard variables defined in `template-default-pipeline-variables.yml`:

- **`environment`** - Target environment (dev, test, prod)
- **`serviceConnection`** - Automatically selected based on environment:
  - dev → `Ume_ServiceConnection_Dev_2.0`
  - test → `Ume_ServiceConnection_Test-Turkos`
  - prod → `Ume_ServiceConnection_Prod-Turkos`
- **`buildName`** - Automatically generated from branch and environment

## Support

For questions or issues with these templates, contact Team Turkos.

---

**Maintained by:** Umeå kommun Team Turkos\
**Last Updated:** October 2025
