Mattermost 

A role to install mattermost on OpenShift. Currently this role only supports deployment via a Red Hat written mattermost operator. 

Requirements
------------

This role currently supports the deployment of Mattermost via operator. For more information on the operator please visit [this link](https://github.com/RedHatGov/mattermost-operator). If you are planning to run this role to deploy Mattermost via the operator deployment in a disconnected environment, the following images must be available (this operator deployment assumes the operator is subscibable via operatorhub):

* quay.io/redhatgov/mattermost-operator:v1.0.0
* quay.io/redhatgov/mattermost-operator-bundle:1.0.0
* quay.io/redhatgov/operator-catalog:1.2.0
* mattermost/mattermost-team-edition:latest
* registry.redhat.io/rhscl/postgresql-12-rhel7:latest

Additionally using the quay.io/redhatgov/operator-catalog image, a `CatalogSource` should be built to provide the subscription functionality. The sample `CatalogSource` below can be added to your cluster to meet this requirement:

```
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: redhatgov-operators
  namespace: openshift-marketplace
spec:
  displayName: Red Hat NAPS Community Operators
  icon:
    base64data: ''
    mediatype: ''
  image: 'quay.io/redhatgov/operator-catalog:1.2.0'
  publisher: RedHatGov
  sourceType: grpc
  updateStrategy:
    registryPoll:
      interval: 30m
```

This role also requires the openshift and kubenetes python packages.

Role Variables
--------------

The role variables here provided by default (default/main.yml), and that can be specified specifically, are largely derived from the parameters used for the [Mattermost CR](https://github.com/RedHatGov/mattermost-operator/blob/main/config/samples/advanced_mattermost_v1alpha1_mattermost.yaml).

**By default we provide:**

### Mattermost
| Variable | Value | Description |
|----------|-------|-------------|
|`mattermost_name` | `mattermost`|this will be the OpenShift deployment name of your mattermost instance             |
|`mattermost_namespace`| `mattermost-operator`|this will be the namespace to deploy the mattermost operator / and instance |
|`mattermost_operator_channel`|`stable`|operator channel to subscribe to (`stable` and `beta` exist)|

### Database
| Variable | Value | Description |
|----------|-------|-------------|
|`database.drivername`|`postgres`|this is type of database the operator will use or create (in the future capabilities for MYSQL will be added)|
|`database.name`|`mattermost`|this is the name of the database to use or create in the database instance|
|`database.password`|`mattermost`|this is the password for accessing the database|
|`database.port`|`5432`|port to query on database|

**Additional variables you might want to specify:**

### Mattermost
| Variable | Example Value | Description |
|----------|---------------|-------------|
|`mattermost.configStorage.persistentVolumeSize`|`1Gi`|Storage size to provide to mattermost directory `mattermost/config` |
|`mattermost.logStorage.persistentVolumeSize`|`1Gi`|Storage size to provide to mattermost directory `mattermost/logs` |
|`mattermost.dataStorage.persistentVolumeSize`|`1Gi`|Storage size to provide to mattermost directory `mattermost/data` |
|`mattermost.pluginStorage.persistentVolumeSize`|`1Gi`|Storage size to provide to mattermost directory `mattermost/plugins` |

### Authentication
| Variable | Example Value | Description |
|----------|---------------|-------------|
|`authentication.keycloak.realmUrl`|`https://keycloak.apps.example.com/auth/realms/my-realm`|keycloak realm url for SSO|
|`authentication.keycloak.secret`|`mattermost`|keycloak secret for authentication access|

Example Playbook
----------------

**Standard, hassle free deployment:**
```
    - hosts: servers

      roles:
      - role: mattermost
```

**The works:**
```
- hosts: servers

  roles:
  - role: mattermost
    vars:
      mattermost_name: my-org-mattermost
      mattermost_namespace: my-org-mattermost-ns
      mattermost_operator_channel: stable
      database:
        drivername: postgres
        name: my-org-mattermost-database
        password: custom-passwords-are-fun!
        port: 5432
      mattermost:
        configStorage:
          persistentVolumeSize: 1Gi
        logStorage:
          persistentVolumeSize: 3Gi
        dataStorage:
          persistentVolumeSize: 5Gi
        pluginStorage:
          persistentVolumeSize: 2Gi
      authentication:
          keycloak:
            realmUrl: 'https://keycloak.apps.example.com/auth/realms/my-realm'
            secret: 1f6d2d53-6c46-46e9-860c-4ed0c80b703b
```

License
-------
BSD

Author Information
------------------
[Griffin College](https://github.com/griffincollege)
