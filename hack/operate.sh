#!/bin/bash

SCRIPT_ROOT=$(dirname $(realpath $0))
if [ $(basename "$SCRIPT_ROOT") = 'hack' ]; then
    cd "$SCRIPT_ROOT/.."
else
    cd "$SCRIPT_ROOT"
fi

if ! which docker &>/dev/null; then
    if which podman &>/dev/null; then
        function docker { podman "${@}" ; }
    else
        echo "We may not be able to do docker things..." >&2
    fi
fi

function now() {
    date '+%Y%m%dT%H%M%S'
}
# Error handler
function on_error() {
    [ -n "$msg" ] && wrap "$msg" ||:
    echo
    now=$(now)
    mv $log error_$now.log
    chmod 644 error_$now.log
    sync
    wrap "Error on $0 line $1, logs available at error_$now.log" >&2
    [ $1 -eq 0 ] && : || exit $2
}

# Generic exit cleanup helper
function on_exit() {
    unkustomize_namespace &>/dev/null
    rm -f $log
}

# Stage some logging
log=$(mktemp)
if echo "$*" | grep -qF -- '-v' || echo "$*" | grep -qF -- '--verbose'; then
    exec 7> >(tee -a "$log" |& sed 's/^/\n/' >&2)
    FORMATTER_PAD_RESULT=0
else
    exec 7>$log
fi
echo "Logging initialized $(now)" >&7

# Set some traps
trap 'on_error $LINENO $?' ERR
trap 'on_exit' EXIT

# Get some output helpers to keep things clean-ish
if which formatter &>/dev/null; then
    # I keep this on my system. If you want, you can install it yourself:
    #   mkdir -p ~/.local/bin
    #   curl -o ~/.local/bin/formatter https://raw.githubusercontent.com/solacelost/output-formatter/modern-only/formatter
    #   chmod +x ~/.local/bin/formatter
    #   echo "$PATH" | grep -qF "$(realpath ~/.local/bin)" || export PATH="$(realpath ~/.local/bin):$PATH"
    . $(which formatter)
else
    if echo "$*" | grep -qF -- '--formatter'; then
        curl -o ~/.local/bin/formatter https://raw.githubusercontent.com/solacelost/output-formatter/modern-only/formatter
        chmod +x ~/.local/bin/formatter
        . ~/.local/bin/formatter
    else
        # These will work as a poor-man's approximation in just a few lines
        function error_run() {
            echo -n "$1"
            shift
            eval "$@" >&7 2>&1 && echo '  [ SUCCESS ]' || { ret=$? ; echo '  [  ERROR  ]' ; return $ret ; }
        }
        function warn_run() {
            echo -n "$1"
            shift
            eval "$@" >&7 2>&1 && echo '  [ SUCCESS ]' || { ret=$? ; echo '  [ WARNING ]' ; return $ret ; }
        }
        function wrap() {
            if [ $# -gt 0 ]; then
                echo "${@}" | fold -s
            else
                fold -s
            fi
        }
    fi
fi

function print_usage() {
    wrap "usage: $(basename $0) [-h|--help] | " \
         "[--formatter] " \
         "[-v|--verbose] " \
         "[(-i |--image=)IMG] " \
         "[(-k |--kind=)KIND] " \
         "[-r|--remove] " \
         "[-b|--build-artifacts] " \
         "[--build-only] " \
         "[-p|--push-images] " \
         "[--push-only] " \
         "[(-o |--overlay=)DIR] " \
         "[(-n |--namespace=)NS] " \
         "[(-c | --custom-resource=)YAML] " \
         "[-d|--deploy-cr] " \
         "[-u|--undeploy-cr] " \
         "[(-V |--version=)SEMVER] " \
         "[(-C |--channels=)CHANNELS] " \
         "[(-t |--extra-tag=)TAG] " \
         "[--develop] " \
         "[--bundle]"
}

function print_help() {
    print_usage
    cat << 'EOF'

Build an ansible-based operator using only requirements.yml, watches.yml, and
the requisite playbooks/ and roles/ files on the fly. Can complete any and all
stages as part of building artifacts, pushing, installing, and deploying the
application to a cluster directly. Additional bundling or kustomization is
available as well.

OPTIONS
    -h|--help                       Print this help page and exit.
    --formatter                     Download and use the pretty-printing
                                      formatter to execute task runs.
    -v|--verbose                    Output all command output directly to
                                      stderr, making it ugly but debuggable.
    -i |--image=IMG                 Set the image name for the operator to IMG
    -k |--kind=KIND                 Set the Kind of the CRD to KIND
    -r|--remove                     Remove any installed/built operator and
                                      artifacts of that build. Do not build,
                                      push, install, or deploy.
    -b|--build-artifacts            Rebuild deployment artifacts, removing them
                                      and rebuilding as necessary.
    --build-only                    Build artifacts, but don't install them or
                                      do any follow-on actions.
    -p|--push-images                Build and push new operator images to your
                                      tagged registry - you must already be
                                      logged in.
    --push-only                     Build and push new operator images to your
                                      tagged repository, but don't do any
                                      follow-on actions.
    -o |--overlay=DIR               When installing, use the kustomize overlay
                                      present in DIR (as a subdirectory of
                                      config) instead of the one in default.
    -n |--namespace=NS              Set the namespace to deploy the artifacts to
    -c |--custom-resource=YAML      Specify the CR sample file to deploy from
                                      the config/samples directory.
    -d|--deploy-cr                  Deploy a CR for the operator to the cluster.
    -u|--undeploy-cr                Undeploy the CR for the operator.
    -V |--version=SEMVER            Set the operator version to SEMVER for the
                                      purpose of building an operator image and
                                      an OLM bundle.
    -C |--channels=CHANNELS         Set the channels label for the bundle image.
    -t |--extra-tag=TAG             As well as SEMVER, also publish a version
                                      tagged as TAG.
    --develop                       Don't push to the SEMVER tag, either from
                                      operate.conf or the --version option, and
                                      instead push only to the develop tag
    --bundle                        Build and publish an OLM bundle to the tag
                                      at ${IMG}-bundle:${VERSION}

NOTE: If you run with `--push-images` and `--bundle`, no installation will be
      attempted as this combination is intended for CI. Other options will still
      be processed.

EOF
}

function parse_arg() {
    # If the first arg = the second arg, output the third and fail, otherwise
    #   split the second on the first `=` sign and succeed.
    # ex:
    #   -i|--image=*)
    #       IMG=$(parse_arg -i "$1" "$2") || shift
    if [ "$1" = "$2" ]; then
        echo "$3"
        return 1
    else
        echo "$2" | cut -d= -f2-
        return 0
    fi
}

# Un/set defaults
REMOVE_OPERATOR=
IMG=
KIND=
PUSH_IMAGES=
PUSH_ONLY=
BUILD_ARTIFACTS=
BUILD_ONLY=
NAMESPACE=
CR_SAMPLE=
DEPLOY_CR=
UNDEPLOY_CR=
OVERLAY=default
VERSION=
CHANNELS=
DEVLEOP=
BUNDLE=
EXTRA_TAGS=()

# Load the configuration
config=
if [ -f operate.conf ]; then
    config=operate.conf
elif [ -f hack/operate.conf ]; then
    config=hack/operate.conf
fi
if [ "$config" ]; then
    # This uses some simple python to read the .conf file in true ini format,
    #   outputting the variables in an exportable fashion so we can eval them
    #   in the warn_run.
    warn_run "Loading configuration from operate.conf" source $config ||:
fi

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)
            print_help
            exit 0
            ;;
        --formatter)
            true
            ;;
        -v|--verbose)
            true
            ;;
        -r|--remove)
            REMOVE_OPERATOR=true
            ;;
        -i|--image=*)
            IMG=$(parse_arg -i "$1" "$2") || shift
            ;;
        -k|--kind=*)
            KIND=$(parse_arg -k "$1" "$2") || shift
            ;;
        -b|--build-artifacts)
            BUILD_ARTIFACTS=true
            ;;
        --build-only)
            BUILD_ARTIFACTS=true
            BUILD_ONLY=true
            ;;
        -p|--push-images)
            PUSH_IMAGES=true
            ;;
        --push-only)
            PUSH_IMAGES=true
            PUSH_ONLY=true
            ;;
        -o|--overlay=*)
            OVERLAY=$(parse_arg -o "$1" "$2") || shift
            ;;
        -n|--namespace=*)
            NAMESPACE=$(parse_arg -n "$1" "$2") || shift
            ;;
        -c|--custom-resource=*)
            CR_SAMPLE=$(parse_arg -c "$1" "$2") || shift
            ;;
        -d|--deploy-cr)
            DEPLOY_CR=true
            UNDEPLOY_CR=
            ;;
        -u|--undeploy-cr)
            UNDEPLOY_CR=true
            DEPLOY_CR=
            ;;
        -V|--version=*)
            VERSION=$(parse_arg -V "$1" "$2") || shift
            ;;
        -C|--channels=*)
            CHANNELS=$(parse_arg -C "$1" "$2") || shift
            ;;
        -t|--extra-tag=*)
            EXTRA_TAGS+=($(parse_arg -t "$1" "$2")) || shift
            ;;
        --develop)
            DEVELOP=true
            ;;
        --bundle)
            BUNDLE=true
            ;;
        *)
            print_usage >&2
            exit 127
            ;;
    esac ; shift
done

if [ -n "$BUILD_ONLY" -a -n "$PUSH_ONLY" ]; then
    echo "Unable to build and push only" >&2
    print_usage >&2
    exit 1
fi

quay_logged_in=
components_updated=
artifacts_built=
operator_installed=
cluster_validated=
kustomize_validated=
old_namespace=

function update_components() {
    # Ensure we have the things we need to work with the operator-sdk
    if [ -z "$components_updated" ]; then
        if [ "$VIRTUAL_ENV" ]; then
            error_run "Updating the Operator SDK manager" pip install --upgrade operator-sdk-manager || return 1
        else
            error_run "Updating the Operator SDK manager" pip install --user --upgrade operator-sdk-manager || return 1
        fi
        error_run "Updating the Operator SDK" 'sdk_version=$(operator-sdk-manager update -vvvv | cut -d" " -f 3)' || return 1
    fi
    components_updated=true
}

function build_artifacts() {
    # Build the operator artifacts from the provided configuration
    if [ -z "$artifacts_built" ]; then
        if [ -d config ]; then
            remove_artifacts
        fi
        error_run "Initializing Ansible Operator with operator-sdk $sdk_version" operator-sdk init --plugins=ansible --domain=io || return 1
        error_run "Creating API config with operator-sdk $sdk_version" operator-sdk create api --group redhatgov --version v1alpha1 --kind $KIND || return 1
    fi
    artifacts_built=true
}

function quay_login() {
    if [ -z "$quay_logged_in" ]; then
        if [ -n "$QUAY_USER" -a -n "$QUAY_PASSWORD" ]; then
            error_run "Logging in to quay.io with provided credentials" "docker login -u '$QUAY_USER' -p '$QUAY_PASSWORD' quay.io" || return 1
        else
            warn_run "No credentials provided, assuming cached login..." false ||:
        fi
    fi
    quay_logged_in=true
}

function push_images() {
    quay_login || return 1
    # Push the images to the logged in repository
    if [ -z "$DEVELOP" ]; then
        for tag in $VERSION ${EXTRA_TAGS[@]}; do
            error_run "Building $IMG:$tag" make docker-build IMG=$IMG:$tag || return 1
            error_run "Pushing $IMG:$tag" make docker-push IMG=$IMG:$tag || return 1
        done
    else
        error_run "Building $IMG:develop" make docker-build IMG=$IMG:develop || return 1
        error_run "Pushing $IMG:develop" make docker-push IMG=$IMG:develop || return 1
    fi
}

function validate_cluster() {
    if [ -z "$cluster_validated" ]; then
        # Make sure we've got the tooling and cached logins to support application
        error_run "Checking for kubectl in path" which kubectl || return 1
        error_run "Checking for logged in status on cluster" kubectl get nodes || return 1
    fi
    cluster_validated=true
}

function install_operator() {
    # Installs the operator defined by built artifacts to the locally logged in
    #   cluster
    if [ -z "$operator_installed" ]; then
        validate_cluster || return 1
        error_run "Installing operator resources" make install || return 1
        error_run "Deploying operator" make deploy IMG=$IMG:latest OVERLAY=$OVERLAY || return 1
    fi
    operator_installed=true
}

function uninstall_operator() {
    # Uninstalls the operator defined by the built artifacts from the locally
    #   logged in cluster
    validate_cluster || return 1
    undeploy_cr
    warn_run "Undeploying operator" make undeploy IMG=$IMG:latest OVERLAY=$OVERLAY || :
    warn_run "Uninstalling operator resources" make uninstall || :
    operator_installed=
}

function remove_artifacts() {
    # Remove operator artifacts from the tree
    warn_run "Removing operator files" rm -rf PROJECT Makefile Dockerfile bin bundle bundle.Dockerfile config molecule roles/.placeholder playbooks/.placeholder || :
    artifacts_built=
}

function deploy_cr() {
    validate_cluster || return 1
    error_run "Deploying custom resource sample" kubectl apply -f "config/samples/${CR_SAMPLE}" || return 1
}

function undeploy_cr() {
    validate_cluster || return 1
    warn_run "Undeploying custom resource sample" kubectl delete -f "config/samples/${CR_SAMPLE}" ||:
}

function validate_kustomize() {
    if [ -z "$kustomize_validated" ]; then
        error_run "Validating kustomize is installed/downloaded" make kustomize || return 1
        project_root=$(pwd)
        which kustomize &>/dev/null || function kustomize() { "${project_root}/bin/kustomize" "${@}" ; }
    fi
    kustomize_validated=true
}

function kustomize_namespace() {
    validate_kustomize || return 1
    pushd config/$OVERLAY &>/dev/null
    old_namespace=$(awk '/^namespace:/{print $2}' kustomization.yaml)
    error_run "Kustomizing namespace" kustomize edit set namespace "$NAMESPACE" || return 1
    popd &>/dev/null
}

function unkustomize_namespace() {
    if [ -z "$old_namespace" ]; then
        return 0
    fi
    pushd config/$OVERLAY &>/dev/null
    warn_run "Removing namespace kustomization" kustomize edit set namespace "$old_namespace" ||:
    popd &>/dev/null
}

function publish_bundle() {
    update_components || return 1
    validate_kustomize || return 1
    quay_login || return 1
    rm -rf bundle bundle.Dockerfile
    pushd config/rbac &>/dev/null
    error_run "Adding namespaced Role to kustomization" 'kustomize edit add resource namespaced/role.yaml' || return 1
    error_run "Adding namespaced RoleBinding to kustomization" 'kustomize edit add resource namespaced/role_binding.yaml' || return 1
    popd &>/dev/null
    error_run "Building bundle manifests" 'kustomize build --load_restrictor none config/manifests | operator-sdk generate bundle --overwrite --version $VERSION --channels "$CHANNELS"' || return 1
    error_run "Validating bundle" operator-sdk bundle validate ./bundle || return 1
    error_run "Building bundle image" docker build -f bundle.Dockerfile -t "$IMG-bundle:$VERSION" . || return 1
    if [ -z "$DEVELOP" ]; then
        error_run "Pushing image $IMG-bundle:$VERSION" docker push "$IMG-bundle:$VERSION" || return 1
        for tag in ${EXTRA_TAGS[@]}; do
            error_run "Tagging bundle image with $tag" docker tag "$IMG-bundle:$VERSION" "$IMG-bundle:$tag" || return 1
            error_run "Pushing image $IMG-bundle:$tag" docker push "$IMG-bundle:$tag" || return 1
        done
    else
        error_run "Tagging bundle image with develop" docker tag "$IMG-bundle:$VERSION" "$IMG-bundle:develop" || return 1
        error_run "Pushing image $IMG-bundle:develop" docker push "$IMG-bundle:develop" || return 1
    fi
    pushd config/rbac &>/dev/null
    warn_run "Removing namespaced Role from kustomization" 'kustomize edit remove resource namespaced/role.yaml' ||:
    warn_run "Removing namespaced RoleBinding from kustomization" 'kustomize edit remove resource namespaced/role.yaml' ||:
    popd &>/dev/null
}

if [ "$REMOVE_OPERATOR" ]; then
    # Try to remove everything from a cluster
    uninstall_operator || :
else
    if [ "$BUILD_ARTIFACTS" ]; then
        # Build the artifacts necessary to deploy the operator from an image
        #   NOTE: Removes all existing tweaks to built artifacts!
        update_components
        build_artifacts
        if [ "$BUILD_ONLY" ]; then
            exit 0
        fi
    fi
    if [ "$PUSH_IMAGES" ]; then
        # Push the images to a repository
        #   NOTE: REQUIRES YOU TO ACTUALLY LOG IN FIRST
        push_images
        if [ "$PUSH_ONLY" ]; then
            exit 0
        fi
    fi

    if [ "$NAMESPACE" ]; then
        # Ensure kustomize is available and kustomize the namespace
        kustomize_namespace
    fi

    if [ -z "$PUSH_IMAGES" -o -z "$BUNDLE" ]; then
        # Install all of the necessary artifacts
        install_operator
    fi

    # Apply the artifacts to the currently logged in cluster
    if [ "$DEPLOY_CR" ]; then
        deploy_cr
    elif [ "$UNDEPLOY_CR" ]; then
        undeploy_cr
    fi

    if [ "$BUNDLE" ]; then
        publish_bundle
    fi
fi
