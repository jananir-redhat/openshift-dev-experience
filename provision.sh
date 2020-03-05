#!/bin/bash

set -x

echo "###############################################################################"
echo "#  MAKE SURE YOU ARE LOGGED IN:                                               #"
echo "#  $ oc login http://console.your.openshift.com                               #"
echo "###############################################################################"

function usage() {
    echo
    echo "Usage:"
    echo " $0 [command] [options]"
    echo " $0 --help"
    echo
    echo "Example:"
    echo " $0 deploy --project-suffix mydemo"
    echo
    echo "COMMANDS:"
    echo "   deploy                   Set up the demo projects and deploy demo apps"
    echo "   delete                   Clean up and remove demo projects and objects"
    echo "   idle                     Make all demo services idle"
    echo "   unidle                   Make all demo services unidle"
    echo 
    echo "OPTIONS:"
    echo "   --user [username]          Optional    The admin user for the demo projects. Required if logged in as system:admin"
    echo "   --project-suffix [suffix]  Optional    Suffix to be added to demo project names e.g. ci-SUFFIX. If empty, user will be used as suffix"
    echo "   --ephemeral                Optional    Deploy demo without persistent storage. Default false"
    echo "   --oc-options               Optional    oc client options to pass to all oc commands e.g. --server https://my.openshift.com"
    echo
}

ARG_USERNAME=
ARG_PROJECT_SUFFIX=
ARG_COMMAND=
ARG_EPHEMERAL=false
ARG_OC_OPS=

while :; do
    case $1 in
        deploy)
            ARG_COMMAND=deploy
            ;;
        delete)
            ARG_COMMAND=delete
            ;;
        idle)
            ARG_COMMAND=idle
            ;;
        unidle)
            ARG_COMMAND=unidle
            ;;
        --user)
            if [ -n "$2" ]; then
                ARG_USERNAME=$2
                shift
            else
                printf 'ERROR: "--user" requires a non-empty value.\n' >&2
                usage
                exit 255
            fi
            ;;
        --project-suffix)
            if [ -n "$2" ]; then
                ARG_PROJECT_SUFFIX=$2
                shift
            else
                printf 'ERROR: "--project-suffix" requires a non-empty value.\n' >&2
                usage
                exit 255
            fi
            ;;
        --oc-options)
            if [ -n "$2" ]; then
                ARG_OC_OPS=$2
                shift
            else
                printf 'ERROR: "--oc-options" requires a non-empty value.\n' >&2
                usage
                exit 255
            fi
            ;;
        --ephemeral)
            ARG_EPHEMERAL=true
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            break
            ;;
        -?*)
            printf 'WARN: Unknown option (ignored): %s\n' "$1" >&2
            shift
            ;;
        *) # Default case: If no more options then break out of the loop.
            break
    esac

    shift
done


################################################################################
# CONFIGURATION                                                                #
################################################################################

LOGGEDIN_USER=$(oc $ARG_OC_OPS whoami)
OPENSHIFT_USER=${ARG_USERNAME:-$LOGGEDIN_USER}
PRJ_SUFFIX=${ARG_PROJECT_SUFFIX:-`echo $OPENSHIFT_USER | sed -e 's/[-@].*//g'`}

APPDEV_NAMESPACE=appdev-$PRJ_SUFFIX
DEV_PROJECT=dev-$PRJ_SUFFIX
STAGE_PROJECT=stage-$PRJ_SUFFIX
EPHEMERAL=$ARG_EPHEMERAL

function deploy() {
  oc $ARG_OC_OPS new-project dev-$PRJ_SUFFIX   --display-name="Pet Clinic - Dev"
  oc $ARG_OC_OPS new-project stage-$PRJ_SUFFIX --display-name="Pet Clinic - Stage"
  oc $ARG_OC_OPS new-project appdev-$PRJ_SUFFIX  --display-name="AppDev"

  sleep 2

  oc $ARG_OC_OPS policy add-role-to-group edit system:serviceaccounts:appdev-$PRJ_SUFFIX -n dev-$PRJ_SUFFIX
  oc $ARG_OC_OPS policy add-role-to-group edit system:serviceaccounts:appdev-$PRJ_SUFFIX -n stage-$PRJ_SUFFIX

  if [ $LOGGEDIN_USER == 'system:admin' ] ; then
    oc $ARG_OC_OPS adm policy add-role-to-user admin $ARG_USERNAME -n dev-$PRJ_SUFFIX >/dev/null 2>&1
    oc $ARG_OC_OPS adm policy add-role-to-user admin $ARG_USERNAME -n stage-$PRJ_SUFFIX >/dev/null 2>&1
    oc $ARG_OC_OPS adm policy add-role-to-user admin $ARG_USERNAME -n appdev-$PRJ_SUFFIX >/dev/null 2>&1
    
    oc $ARG_OC_OPS annotate --overwrite namespace dev-$PRJ_SUFFIX   demo=openshift-dev-experience-$PRJ_SUFFIX >/dev/null 2>&1
    oc $ARG_OC_OPS annotate --overwrite namespace stage-$PRJ_SUFFIX demo=openshift-dev-experience-$PRJ_SUFFIX >/dev/null 2>&1
    oc $ARG_OC_OPS annotate --overwrite namespace appdev-$PRJ_SUFFIX  demo=openshift-dev-experience-$PRJ_SUFFIX >/dev/null 2>&1

    oc $ARG_OC_OPS adm pod-network join-projects --to=appdev-$PRJ_SUFFIX dev-$PRJ_SUFFIX stage-$PRJ_SUFFIX >/dev/null 2>&1
  fi

  oc adm policy add-scc-to-user privileged -z default

  sleep 2

  if [ "${EPHEMERAL}" == "true" ] ; then
    oc new-app jenkins-ephemeral -n appdev-$PRJ_SUFFIX
  else
    oc new-app jenkins-persistent -n appdev-$PRJ_SUFFIX
  fi

  oc set resources dc/jenkins --limits=cpu=2,memory=2Gi --requests=cpu=100m,memory=512Mi
  oc set env dc jenkins INSTALL_PLUGINS=antisamy-markup-formatter:1.6,ansicolor:0.6.2,greenballs:1.15,slack:2.28,badge:1.7,groovy-postbuild:2.5,linenumbers:1.2,jacoco:3.0.5
  oc label dc jenkins app=jenkins --overwrite
  oc label dc jenkins "app.kubernetes.io/part-of"="jenkins" --overwrite

  oc apply -f jenkins-secret.yaml

  # setup dev env
  oc import-image redhat-openjdk-18/openjdk18-openshift --from=registry.access.redhat.com/redhat-openjdk-18/openjdk18-openshift --confirm -n ${DEV_PROJECT}
  
  # dev
  oc new-build --name=petclinic --image-stream=openjdk18-openshift:latest --binary=true -n ${DEV_PROJECT}
  oc new-app petclinic:latest --allow-missing-images -n ${DEV_PROJECT}
  oc set triggers dc -l app=petclinic --containers=petclinic --from-image=petclinic:latest --manual -n ${DEV_PROJECT}
  
  # stage
  oc new-app petclinic:stage --allow-missing-images -n ${STAGE_PROJECT}
  oc set triggers dc -l app=petclinic --containers=petclinic --from-image=petclinic:stage --manual -n ${STAGE_PROJECT}
  
  # dev project
  oc expose dc/petclinic --port=8080 -n ${DEV_PROJECT}
  oc expose svc/petclinic -n ${DEV_PROJECT}
  oc set probe dc/petclinic --readiness --get-url=http://:8080/ --initial-delay-seconds=90 --failure-threshold=10 --period-seconds=10 --timeout-seconds=3 -n ${DEV_PROJECT}
  oc set probe dc/petclinic --liveness  --get-url=http://:8080/ --initial-delay-seconds=180 --failure-threshold=10 --period-seconds=10 --timeout-seconds=3 -n ${DEV_PROJECT}
  oc rollout cancel dc/petclinic -n ${STAGE_PROJECT}

  # stage project
  oc expose dc/petclinic --port=8080 -n ${STAGE_PROJECT}
  oc expose svc/petclinic -n ${STAGE_PROJECT}
  oc set probe dc/petclinic --readiness --get-url=http://:8080/ --initial-delay-seconds=90 --failure-threshold=10 --period-seconds=10 --timeout-seconds=3 -n ${STAGE_PROJECT}
  oc set probe dc/petclinic --liveness  --get-url=http://:8080/ --initial-delay-seconds=180 --failure-threshold=10 --period-seconds=10 --timeout-seconds=3 -n ${STAGE_PROJECT}
  oc rollout cancel dc/petclinic -n ${DEV_PROJECT}

  # deploy gogs
  HOSTNAME=$(oc get route jenkins -o template --template='{{.spec.host}}' | sed "s/jenkins-${APPDEV_NAMESPACE}.//g")
  GOGS_HOSTNAME="gogs-$APPDEV_NAMESPACE.$HOSTNAME"

  if [ "${EPHEMERAL}" == "true" ] ; then
    oc new-app -f https://raw.githubusercontent.com/OpenShiftDemos/gogs-openshift-docker/master/openshift/gogs-template.yaml \
        --param=GOGS_VERSION=0.11.34 \
        --param=DATABASE_VERSION=9.6 \
        --param=HOSTNAME=$GOGS_HOSTNAME \
        --param=SKIP_TLS_VERIFY=true
  else
    oc new-app -f https://raw.githubusercontent.com/OpenShiftDemos/gogs-openshift-docker/master/openshift/gogs-persistent-template.yaml \
        --param=GOGS_VERSION=0.11.34 \
        --param=DATABASE_VERSION=9.6 \
        --param=HOSTNAME=$GOGS_HOSTNAME \
        --param=SKIP_TLS_VERIFY=true
  fi

  oc label dc gogs "app.kubernetes.io/part-of"="gogs" --overwrite
  oc label dc gogs-postgresql "app.kubernetes.io/part-of"="gogs" --overwrite

  helm install sonarqube stable/sonarqube -f charts/sonarqube/values.yaml
  oc apply -f sonarqube-route.yaml

  if [ "${EPHEMERAL}" == "true" ] ; then
    oc new-app -f https://raw.githubusercontent.com/OpenShiftDemos/nexus/master/nexus3-template.yaml --param=NEXUS_VERSION=3.13.0 --param=MAX_MEMORY=2Gi
  else
    oc new-app -f https://raw.githubusercontent.com/OpenShiftDemos/nexus/master/nexus3-persistent-template.yaml --param=NEXUS_VERSION=3.13.0 --param=MAX_MEMORY=2Gi
  fi

  oc set resources dc/nexus --requests=cpu=200m --limits=cpu=2
  oc label dc nexus "app.kubernetes.io/part-of"="nexus" --overwrite

  WEBHOOK_SECRET=$(openssl rand -hex 4)

  oc $ARG_OC_OPS new-app -f appdev-infra.yaml -p DEV_PROJECT=dev-$PRJ_SUFFIX -p STAGE_PROJECT=stage-$PRJ_SUFFIX -p EPHEMERAL=$ARG_EPHEMERAL -p WEBHOOK_SECRET=$WEBHOOK_SECRET -n appdev-$PRJ_SUFFIX

  while [ -z "$(oc get job appdev-demo-installer | grep '1/1')" ]
  do
    echo
    echo 'waiting for the job appdev-demo-installer to be complete...'
    oc get job appdev-demo-installer
    sleep 2
  done

  oc $ARG_OC_OPS new-app -f build-config.yaml -p DEV_PROJECT=dev-$PRJ_SUFFIX -p STAGE_PROJECT=stage-$PRJ_SUFFIX -p EPHEMERAL=$ARG_EPHEMERAL -p WEBHOOK_SECRET=$WEBHOOK_SECRET -n appdev-$PRJ_SUFFIX


  oc apply -f codeready-workspaces-operator.yaml

  sleep 2

  oc rollout status deploy/codeready-operator -w

  sleep 2

  oc apply -f che-cluster.yaml

  while [ -z "$(oc describe CheCluster | egrep 'Che\s+Cluster\s+Running:\s+Available')" ]
  do
    echo
    echo 'waiting for Che Cluster status to be Available...'
    oc describe CheCluster | egrep 'Che\s+Cluster\s+Running:'
    sleep 2
  done

  oc rollout status deploy/postgres -w
  oc rollout status deploy/keycloak -w
  oc rollout status deploy/codeready -w
  oc rollout status deploy/devfile-registry -w
  oc rollout status deploy/plugin-registry -w

  oc label deploy codeready-operator "app.kubernetes.io/part-of"="codeready-workspaces" --overwrite
  oc label deploy codeready "app.kubernetes.io/part-of"="codeready-workspaces" --overwrite
  oc label deploy devfile-registry "app.kubernetes.io/part-of"="codeready-workspaces" --overwrite
  oc label deploy plugin-registry "app.kubernetes.io/part-of"="codeready-workspaces" --overwrite
  oc label deploy postgres "app.kubernetes.io/part-of"="codeready-workspaces" --overwrite
  oc label deploy keycloak "app.kubernetes.io/part-of"="codeready-workspaces" --overwrite
}

function make_idle() {
  echo_header "Idling Services"
  oc $ARG_OC_OPS idle -n dev-$PRJ_SUFFIX --all
  oc $ARG_OC_OPS idle -n stage-$PRJ_SUFFIX --all
  oc $ARG_OC_OPS idle -n appdev-$PRJ_SUFFIX --all
}

function make_unidle() {
  echo_header "Unidling Services"
  local _DIGIT_REGEX="^[[:digit:]]*$"

  for project in dev-$PRJ_SUFFIX stage-$PRJ_SUFFIX appdev-$PRJ_SUFFIX
  do
    for dc in $(oc $ARG_OC_OPS get dc -n $project -o=custom-columns=:.metadata.name); do
      local replicas=$(oc $ARG_OC_OPS get dc $dc --template='{{ index .metadata.annotations "idling.alpha.openshift.io/previous-scale"}}' -n $project 2>/dev/null)
      if [[ $replicas =~ $_DIGIT_REGEX ]]; then
        oc $ARG_OC_OPS scale --replicas=$replicas dc $dc -n $project
      fi
    done
  done
}

function set_default_project() {
  if [ $LOGGEDIN_USER == 'system:admin' ] ; then
    oc $ARG_OC_OPS project default >/dev/null
  fi
}

function remove_storage_claim() {
  local _DC=$1
  local _VOLUME_NAME=$2
  local _CLAIM_NAME=$3
  local _PROJECT=$4
  oc $ARG_OC_OPS volumes dc/$_DC --name=$_VOLUME_NAME --add -t emptyDir --overwrite -n $_PROJECT
  oc $ARG_OC_OPS delete pvc $_CLAIM_NAME -n $_PROJECT >/dev/null 2>&1
}

function echo_header() {
  echo
  echo "########################################################################"
  echo $1
  echo "########################################################################"
}

################################################################################
# MAIN: DEPLOY DEMO                                                            #
################################################################################

if [ "$LOGGEDIN_USER" == 'system:admin' ] && [ -z "$ARG_USERNAME" ] ; then
  # for verify and delete, --project-suffix is enough
  if [ "$ARG_COMMAND" == "delete" ] || [ "$ARG_COMMAND" == "verify" ] && [ -z "$ARG_PROJECT_SUFFIX" ]; then
    echo "--user or --project-suffix must be provided when running $ARG_COMMAND as 'system:admin'"
    exit 255
  # deploy command
  elif [ "$ARG_COMMAND" != "delete" ] && [ "$ARG_COMMAND" != "verify" ] ; then
    echo "--user must be provided when running $ARG_COMMAND as 'system:admin'"
    exit 255
  fi
fi


if [[ ! -e jenkins-secret.yaml ]]; then
  echo "jenkins-secret.yaml does not exist! please create an image pull secret:
  https://access.redhat.com/terms-based-registry/
  
  make sure the secret is named: jenkins-pull-secret"
  exit 255
fi

START=`date +%s`

echo_header "OpenShift AppDev Demo ($(date))"

case "$ARG_COMMAND" in
    delete)
        echo "Delete demo..."
        oc $ARG_OC_OPS delete project dev-$PRJ_SUFFIX stage-$PRJ_SUFFIX appdev-$PRJ_SUFFIX
        echo
        echo "Delete completed successfully!"
        ;;
      
    idle)
        echo "Idling demo..."
        make_idle
        echo
        echo "Idling completed successfully!"
        ;;

    unidle)
        echo "Unidling demo..."
        make_unidle
        echo
        echo "Unidling completed successfully!"
        ;;

    deploy)
        echo "Deploying demo..."
        deploy
        echo
        echo "Provisioning completed successfully!"
        ;;
        
    *)
        echo "Invalid command specified: '$ARG_COMMAND'"
        usage
        ;;
esac

set_default_project

END=`date +%s`
echo "(Completed in $(( ($END - $START)/60 )) min $(( ($END - $START)%60 )) sec)"
