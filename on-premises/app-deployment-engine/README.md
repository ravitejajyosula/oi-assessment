# App Deployment Engine
## Day2 Operations
This project provides an engine for deploying applications on-premises.
### Features
- Automated application deployment
- Helmified argocd application and OI-APP deployment 

#### Workflow for the Automated deployment
We have Helmified full deployment resources so that we can easily maintain, scale and reuse. 

We have created a chart `argocd-apps` which will take list of apps to be created and created the apps in argocd
```yaml

apps:
  - name: frontend-deployment
    valuesFile: frontend-deployment/config/values.yaml
    chartFile: frontend-deployment/Chart.yaml
    namespace: oi-my-app
    repoURL: git@github.oi.com:platform/oi-my-app.git
    targetRevision: main
    labels:
      app: oi-my-app-frontend
  # Second app and .... 
argocd:
  namespace: argocd
  destinationServer: https://kubernetes.default.svc

syncPolicy:
  prune: false
  selfHeal: true
globalLabels:
  app: oi-my-app
  environment: dev # Prod, uat or we can  use github.environment if we are using github pipelines
  team: app-deployment-engine
```
#### New App or Service onboarding 
When ever new service or application is added simply add another element to `apps` with required information which will create the application in argocd because argocd is monitoring will be monitoring this folder for changes on specific branch. 

Assume each folder starts with `oi-my-app` is a repository 

there will be three repositories
- github.oi.com:oi/oi-my-app-backend.git
- github.oi.com:oi/oi-my-app-frontend.git
- github.oi.com:oi/oi-my-app-db.git

Whenever developer changes the code. The Deployment workflow will be. 

```
[Image  built and pushed from repo]
↓
[Trigger test workflow in Github or Jenkins]
↓
[Pull that image and run unit tests]
↓
[If tests pass → wait for manual approval(if needed) ]
↓
[Update GitOps repo values.yaml in app-deployment engine with image tag]
↓
[ArgoCD auto-syncs the deployment]

```
#### Release flow (suggested or best practice)

```yaml 
Feature/Fix Branch created 
↓
Pull Request
↓
CI Validation
↓
Merge to Main
↓
Create Release (Tag) 
↓
Release Workflow 
↓
Build & Deploy
```

##### Git hub workflow (Most recommended)

``` yaml
name: Deploy frontend on Release
description:  frontend application on a new release by running tests and updating the GitOps repository.

on:
  release:
    types: [published]

jobs:
  run-tests:
    runs-on: oi-runner
    outputs:
      image_tag: ${{ steps.set-tag.outputs.image_tag }}

    steps:
      - name: Set image tag
        id: set-tag
        run: echo "image_tag=${{ github.event.release.tag_name }}" >> $GITHUB_OUTPUT

      - name: Pull Image
        run: |
          docker pull image-registry.oi.com/oi-frontend:${{ github.event.release.tag_name }}

      - name: Run Tests
        run: |
          docker run --rm image-registry.oi.com/oi-frontend:${{ github.event.release.tag_name }} ./run-tests.sh

  wait-for-approval:
    needs: run-tests
    runs-on: oi-runner
    environment: production
    steps:
      - name: Approval gate passed
        run: echo "Proceeding to update GitOps repo"

  update-gitops:
    needs: wait-for-approval
    runs-on: oi-runner

    steps:
      - name: Checkout repository
        uses: actions/checkout@v4

      - name: Update tag in values.yaml
        run: |
          sed -i "s|tag: .*|tag: ${{ needs.run-tests.outputs.image_tag }}|" frontend/config/values.yaml

      - name: Import GPG key for signing commits
        uses: crazy-max/ghaction-import-gpg@v4
        with:
          gpg_private_key: ${{ secrets.BOT_GPG_PRIVATE_KEY }}
          passphrase: ${{ secrets.BOT_GPG_PASSPHRASE }}
          git_config_global: true
          git_user_signingkey: true
          git_commit_gpgsign: true

      - name: Commit and push changes
        run: |
          git config user.name "GitHub Actions"
          git config user.email "actions@github.com"
          git add frontend/config/values.yaml
          git commit -S -m "chore: update frontend image to ${{ needs.run-tests.outputs.image_tag }}"
          git push
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
##Signed commits so that argocd will sync this commit 
```
Same way above write workflow in all the repos `backend` and also in `db`

We can also use external CI tool out of github. 