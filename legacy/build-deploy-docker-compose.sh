#!/bin/bash

# get the buildname from the pod, $HOSTNAME contains this in the running pod, so we can use this
# set it to something usable here
LAGOON_BUILD_NAME=$HOSTNAME

BUILD_WARNING_COUNT=0

function cronScheduleMoreOftenThan30Minutes() {
  #takes a unexpanded cron schedule, returns 0 if it's more often that 30 minutes
  MINUTE=$(echo $1 | (read -a ARRAY; echo ${ARRAY[0]}) )
  if [[ $MINUTE =~ ^(M|H|\*)\/([0-5]?[0-9])$ ]]; then
    # Match found for M/xx, H/xx or */xx
    # Check if xx is smaller than 30, which means this cronjob runs more often than every 30 minutes.
    STEP=${BASH_REMATCH[2]}
    if [ $STEP -lt 30 ]; then
      return 0
    else
      return 1
    fi
  elif [[ $MINUTE =~ ^\*$ ]]; then
    # We are running every minute
    return 0
  else
    # all other cases are more often than 30 minutes
    return 1
  fi
}

function contains() {
    [[ $1 =~ (^|[[:space:]])$2($|[[:space:]]) ]] && return 0 || return 1
}

# featureFlag searches for feature flag variables in the following locations
# and order:
#
# 1. The cluster-force feature flag, prefixed with LAGOON_FEATURE_FLAG_FORCE_,
#    as a build pod environment variable. This is set via a flag on the
#    build-deploy controller. This overrides the other variables and allows
#    policy enforcement at the cluster level.
#
# 2. The regular feature flag, prefixed with LAGOON_FEATURE_FLAG_, in the
#    Lagoon environment global scoped env-vars. This allows policy control at
#    the environment level.
#
# 3. The regular feature flag, prefixed with LAGOON_FEATURE_FLAG_, in the
#    Lagoon project global scoped env-vars. This allows policy control at the
#    project level.
#
# 4. The cluster-default feature flag, prefixed with
#    LAGOON_FEATURE_FLAG_DEFAULT_, as a build pod environment variable. This is
#    set via a flag on the build-deploy controller. This allows default policy
#    to be set at the cluster level, but maintains the ability to selectively
#    override at the project or environment level.
#
# The value of the first variable found is printed to stdout. If the variable
# is not found, print an empty string. Additional arguments are ignored.
function featureFlag() {
	# check for argument
	[ "$1" ] || return

	local forceFlagVar defaultFlagVar flagVar

	# check build pod environment for the force policy first
	forceFlagVar="LAGOON_FEATURE_FLAG_FORCE_$1"
	[ "${!forceFlagVar}" ] && echo "${!forceFlagVar}" && return

	flagVar="LAGOON_FEATURE_FLAG_$1"
	# check Lagoon environment variables
	flagValue=$(jq -r '.[] | select(.scope == "global" and .name == "'"$flagVar"'") | .value' <<<"$LAGOON_ENVIRONMENT_VARIABLES")
	[ "$flagValue" ] && echo "$flagValue" && return
	# check Lagoon project variables
	flagValue=$(jq -r '.[] | select(.scope == "global" and .name == "'"$flagVar"'") | .value' <<<"$LAGOON_PROJECT_VARIABLES")
	[ "$flagValue" ] && echo "$flagValue" && return

	# fall back to the default, if set.
	defaultFlagVar="LAGOON_FEATURE_FLAG_DEFAULT_$1"
	echo "${!defaultFlagVar}"
}

function projectEnvironmentVariableCheck() {
	# check for argument
	[ "$1" ] || return

	local flagVar

	flagVar="$1"
	# check Lagoon environment variables
	flagValue=$(jq -r '.[] | select(.name == "'"$flagVar"'") | .value' <<<"$LAGOON_ENVIRONMENT_VARIABLES")
	[ "$flagValue" ] && echo "$flagValue" && return
	# check Lagoon project variables
	flagValue=$(jq -r '.[] | select(.name == "'"$flagVar"'") | .value' <<<"$LAGOON_PROJECT_VARIABLES")
	[ "$flagValue" ] && echo "$flagValue" && return

	echo "$2"
}

set +x
SCC_CHECK=$(kubectl -n ${NAMESPACE} get pod ${LAGOON_BUILD_NAME} -o json | jq -r '.metadata.annotations."openshift.io/scc" // false')
set -x

function beginBuildStep() {
  [ "$1" ] || return #Buildstep start
  [ "$2" ] || return #buildstep

  echo -e "##############################################\nBEGIN ${1}\n##############################################"

  # patch the buildpod with the buildstep
  if [ "${SCC_CHECK}" == false ]; then
    kubectl patch -n ${NAMESPACE} pod ${LAGOON_BUILD_NAME} \
      -p "{\"metadata\":{\"labels\":{\"lagoon.sh/buildStep\":\"${2}\"}}}" &> /dev/null
    # tiny sleep to allow patch to complete before logs roll again
    sleep 0.5s
  fi
}

function patchBuildStep() {
  [ "$1" ] || return #total start time
  [ "$2" ] || return #step start time
  [ "$3" ] || return #previous step end time
  [ "$4" ] || return #namespace
  [ "$5" ] || return #buildstep
  [ "$6" ] || return #buildstep
  [ "$7" ] || return #has warnings
  totalStartTime=$(date -d "${1}" +%s)
  startTime=$(date -d "${2}" +%s)
  endTime=$(date -d "${3}" +%s)
  timeZone=$(date +"%Z")

  diffSeconds="$(($endTime-$startTime))"
  diffTime=$(date -d @${diffSeconds} +"%H:%M:%S" -u)

  diffTotalSeconds="$(($endTime-$totalStartTime))"
  diffTotalTime=$(date -d @${diffTotalSeconds} +"%H:%M:%S" -u)

  hasWarnings=""
  if [ "${7}" == "true" ]; then
    hasWarnings=" WithWarnings"
  fi

  echo -e "##############################################\nSTEP ${6}: Completed at ${3} (${timeZone}) Duration ${diffTime} Elapsed ${diffTotalTime}${hasWarnings}\n##############################################"
}

##############################################
### PREPARATION
##############################################

set +x
buildStartTime="$(date +"%Y-%m-%d %H:%M:%S")"
beginBuildStep "Initial Environment Setup" "initialSetup"
echo "STEP: Preparation started ${buildStartTime}"
set -x

##############################################
### PUSH the latest .lagoon.yml into lagoon-yaml configmap as a pre-deploy field
##############################################

set +x

# set the imagecache registry if it is provided
IMAGECACHE_REGISTRY=""
if [ ! -z "$(featureFlag IMAGECACHE_REGISTRY)" ]; then
  IMAGECACHE_REGISTRY=$(featureFlag IMAGECACHE_REGISTRY)
  # add trailing slash if it is missing
  length=${#IMAGECACHE_REGISTRY}
  last_char=${IMAGECACHE_REGISTRY:length-1:1}
  [[ $last_char != "/" ]] && IMAGECACHE_REGISTRY="$IMAGECACHE_REGISTRY/"; :
fi

# Load path of docker-compose that should be used
DOCKER_COMPOSE_YAML=($(cat .lagoon.yml | shyaml get-value docker-compose-yaml))

echo "Updating lagoon-yaml configmap with a pre-deploy version of the .lagoon.yml file"
if kubectl -n ${NAMESPACE} get configmap lagoon-yaml &> /dev/null; then
  # replace it
  # if the environment has already been deployed with an existing configmap that had the file in the key `.lagoon.yml`
  # just nuke the entire configmap and replace it with our new key and file
  LAGOON_YML_CM=$(kubectl -n ${NAMESPACE} get configmap lagoon-yaml -o json)
  if [ "$(echo ${LAGOON_YML_CM} | jq -r '.data.".lagoon.yml" // false')" == "false" ]; then
    # if the key doesn't exist, then just update the pre-deploy yaml only
    kubectl -n ${NAMESPACE} get configmap lagoon-yaml -o json | jq --arg add "`cat .lagoon.yml`" '.data."pre-deploy" = $add' | kubectl apply -f -
  else
    # if the key does exist, then nuke it and put the new key
    kubectl -n ${NAMESPACE} create configmap lagoon-yaml --from-file=pre-deploy=.lagoon.yml -o yaml --dry-run=client | kubectl replace -f -
  fi
 else
  # create it
  kubectl -n ${NAMESPACE} create configmap lagoon-yaml --from-file=pre-deploy=.lagoon.yml
fi
echo "Updating docker-compose-yaml configmap with a pre-deploy version of the docker-compose.yml file"
if kubectl -n ${NAMESPACE} get configmap docker-compose-yaml &> /dev/null; then
  # replace it
  # if the environment has already been deployed with an existing configmap that had the file in the key `docker-compose.yml`
  # just nuke the entire configmap and replace it with our new key and file
  LAGOON_YML_CM=$(kubectl -n ${NAMESPACE} get configmap docker-compose-yaml -o json)
  if [ "$(echo ${LAGOON_YML_CM} | jq -r '.data."docker-compose.yml" // false')" == "false" ]; then
    # if the key doesn't exist, then just update the pre-deploy yaml only
    kubectl -n ${NAMESPACE} get configmap docker-compose-yaml -o json | jq --arg add "`cat ${DOCKER_COMPOSE_YAML}`" '.data."pre-deploy" = $add' | kubectl apply -f -
  else
    # if the key does exist, then nuke it and put the new key
    kubectl -n ${NAMESPACE} create configmap docker-compose-yaml --from-file=pre-deploy=${DOCKER_COMPOSE_YAML} -o yaml --dry-run=client | kubectl replace -f -
  fi
 else
  # create it
  kubectl -n ${NAMESPACE} create configmap docker-compose-yaml --from-file=pre-deploy=${DOCKER_COMPOSE_YAML}
fi

set +ex
currentStepEnd="$(date +"%Y-%m-%d %H:%M:%S")"
patchBuildStep "${buildStartTime}" "${buildStartTime}" "${currentStepEnd}" "${NAMESPACE}" "initialSetup" "Initial Environment Setup" "false"
previousStepEnd=${currentStepEnd}
beginBuildStep "Docker Compose Validation" "dockerComposeValidation"
DOCKER_COMPOSE_WARNING_COUNT=0
##############################################
### RUN docker compose config check against the provided docker-compose file
### use the `build-validate` built in validater to run over the provided docker-compose file
##############################################
dccOutput=$(bash -c 'build-deploy-tool validate docker-compose --docker-compose '${DOCKER_COMPOSE_YAML}'; exit $?' 2>&1)
dccExit=$?
if [ "${dccExit}" != "0" ]; then
  currentStepEnd="$(date +"%Y-%m-%d %H:%M:%S")"
  patchBuildStep "${buildStartTime}" "${previousStepEnd}" "${currentStepEnd}" "${NAMESPACE}" "dockerComposeValidationError" "Docker Compose Validation" "false"
  previousStepEnd=${currentStepEnd}
  echo "
##############################################
Warning!
There are issues with your docker compose file that lagoon uses that should be fixed.
You can run docker compose config locally to check that your docker-compose file is valid.
##############################################
"
  echo ${dccOutput}
  echo "
##############################################"
  exit 1
fi

## validate the docker-compose in a way to eventually phase out forked library by displaying warnings
dccOutput=$(bash -c 'build-deploy-tool validate docker-compose --ignore-non-string-key-errors=false --ignore-missing-env-files=false --docker-compose '${DOCKER_COMPOSE_YAML}'; exit $?' 2>&1)
dccExit=$?
if [ "${dccExit}" != "0" ]; then
  ((++BUILD_WARNING_COUNT))
  ((++DOCKER_COMPOSE_WARNING_COUNT))
  echo "
##############################################
Warning!
There are issues with your docker compose file that lagoon uses that should be fixed.
You can run docker compose config locally to check that your docker-compose file is valid.
"
  if [[ "${dccOutput}" =~ "no such file or directory" ]]; then
    echo "> an env_file is defined in your docker-compose file, but no matching file found."
  fi
  if [[ "${dccOutput}" =~ "Non-string key" ]]; then
    echo "> an invalid string key was detected in your docker-compose file."
  fi
  echo ERR: ${dccOutput}
  echo ""
fi

dccOutput=$(bash -c 'build-deploy-tool validate docker-compose-with-errors --docker-compose '${DOCKER_COMPOSE_YAML}'; exit $?' 2>&1)
dccExit2=$?
if [ "${dccExit2}" != "0" ]; then
  ((++DOCKER_COMPOSE_WARNING_COUNT))
  if [ "${dccExit}" == "0" ]; then
    ((++BUILD_WARNING_COUNT))
    echo "
##############################################
Warning!
There are issues with your docker compose file that lagoon uses that should be fixed.
You can run docker compose config locally to check that your docker-compose file is valid.
"
  fi
  echo "> There are yaml validation errors in your docker-compose file that should be corrected."
  echo ERR: ${dccOutput}
  echo ""
fi

if [[ "$DOCKER_COMPOSE_WARNING_COUNT" -gt 0 ]]; then
  echo "Read the docs for more on errors displayed here https://docs.lagoon.sh/lagoon-build-errors
"
  echo "##############################################"
  currentStepEnd="$(date +"%Y-%m-%d %H:%M:%S")"
  patchBuildStep "${buildStartTime}" "${previousStepEnd}" "${currentStepEnd}" "${NAMESPACE}" "dockerComposeValidationWarning" "Docker Compose Validation" "true"
  previousStepEnd=${currentStepEnd}
else
  currentStepEnd="$(date +"%Y-%m-%d %H:%M:%S")"
  patchBuildStep "${buildStartTime}" "${previousStepEnd}" "${currentStepEnd}" "${NAMESPACE}" "dockerComposeValidation" "Docker Compose Validation" "false"
  previousStepEnd=${currentStepEnd}
fi

beginBuildStep ".lagoon.yml Validation" "lagoonYmlValidation"
##############################################
### RUN lagoon-yml validation against the final data which may have overrides
### from .lagoon.override.yml file or LAGOON_YAML_OVERRIDE environment variable
##############################################
lyvOutput=$(bash -c 'build-deploy-tool validate lagoon-yml; exit $?' 2>&1)
lyvExit=$?

if [ "${lyvExit}" != "0" ]; then
  currentStepEnd="$(date +"%Y-%m-%d %H:%M:%S")"
  patchBuildStep "${buildStartTime}" "${previousStepEnd}" "${currentStepEnd}" "${NAMESPACE}" "lagoonYmlValidationError" ".lagoon.yml Validation" "false"
  previousStepEnd=${currentStepEnd}
  echo "
##############################################
Warning!
There are issues with your .lagoon.yml file that must be fixed.
Refer to the .lagoon.yml docs for the correct syntax
https://docs.lagoon.sh/using-lagoon-the-basics/lagoon-yml/
##############################################
"
  echo "${lyvOutput}"
  echo "
##############################################"
  exit 1
fi
set -ex

set +x
# Validate .lagoon.yml only, no overrides. lagoon-linter still has checks that
# aren't in build-deploy-tool.
if ! lagoon-linter; then
	echo "https://docs.lagoon.sh/lagoon/using-lagoon-the-basics/lagoon-yml#restrictions describes some possible reasons for this build failure."
	echo "If you require assistance to fix this error, please contact support."
	exit 1
else
	echo "lagoon-linter found no issues with the .lagoon.yml file"
fi

currentStepEnd="$(date +"%Y-%m-%d %H:%M:%S")"
patchBuildStep "${buildStartTime}" "${previousStepEnd}" "${currentStepEnd}" "${NAMESPACE}" "lagoonYmlValidation" ".lagoon.yml Validation" "false"
previousStepEnd=${currentStepEnd}
beginBuildStep "Configure Variables" "configuringVariables"
set -x
DEPLOY_TYPE=$(cat .lagoon.yml | shyaml get-value environments.${BRANCH//./\\.}.deploy-type default)

# Load all Services that are defined
COMPOSE_SERVICES=($(cat $DOCKER_COMPOSE_YAML | shyaml keys services))

# Default shared mariadb service broker
MARIADB_SHARED_DEFAULT_CLASS="lagoon-dbaas-mariadb-apb"
MONGODB_SHARED_DEFAULT_CLASS="lagoon-maas-mongodb-apb"

# Figure out which services should we handle
SERVICE_TYPES=()
IMAGES=()
NATIVE_CRONJOB_CLEANUP_ARRAY=()
DBAAS=()
declare -A MAP_DEPLOYMENT_SERVICETYPE_TO_IMAGENAME
declare -A MAP_SERVICE_TYPE_TO_COMPOSE_SERVICE
declare -A MAP_SERVICE_NAME_TO_IMAGENAME
declare -A MAP_SERVICE_NAME_TO_SERVICEBROKER_CLASS
declare -A MAP_SERVICE_NAME_TO_SERVICEBROKER_PLAN
declare -A MAP_SERVICE_NAME_TO_DBAAS_ENVIRONMENT
declare -A IMAGES_PULL
declare -A IMAGES_BUILD
declare -A IMAGE_HASHES

set +x
HELM_ARGUMENTS=()
. /kubectl-build-deploy/scripts/kubectl-get-cluster-capabilities.sh
for CAPABILITIES in "${CAPABILITIES[@]}"; do
  HELM_ARGUMENTS+=(-a "${CAPABILITIES}")
done
set -x

set +x # reduce noise in build logs
# Allow the servicetype be overridden by the lagoon API
# This accepts colon separated values like so `SERVICE_NAME:SERVICE_TYPE_OVERRIDE`, and multiple overrides
# separated by commas
# Example 1: mariadb:mariadb-dbaas < tells any docker-compose services named mariadb to use the mariadb-dbaas service type
# Example 2: mariadb:mariadb-dbaas,nginx:nginx-persistent
if [ ! -z "$LAGOON_PROJECT_VARIABLES" ]; then
  LAGOON_SERVICE_TYPES=($(echo $LAGOON_PROJECT_VARIABLES | jq -r '.[] | select(.name == "LAGOON_SERVICE_TYPES") | "\(.value)"'))
fi
if [ ! -z "$LAGOON_ENVIRONMENT_VARIABLES" ]; then
  TEMP_LAGOON_SERVICE_TYPES=($(echo $LAGOON_ENVIRONMENT_VARIABLES | jq -r '.[] | select(.name == "LAGOON_SERVICE_TYPES") | "\(.value)"'))
  if [ ! -z $TEMP_LAGOON_SERVICE_TYPES ]; then
    LAGOON_SERVICE_TYPES=$TEMP_LAGOON_SERVICE_TYPES
  fi
fi
# Allow the dbaas environment type to be overridden by the lagoon API
# This accepts colon separated values like so `SERVICE_NAME:DBAAS_ENVIRONMENT_TYPE`, and multiple overrides
# separated by commas
# Example 1: mariadb:production < tells any docker-compose services named mariadb to use the production dbaas environment type
# Example 2: mariadb:production,mariadb-test:development
if [ ! -z "$LAGOON_PROJECT_VARIABLES" ]; then
  LAGOON_DBAAS_ENVIRONMENT_TYPES=($(echo $LAGOON_PROJECT_VARIABLES | jq -r '.[] | select(.name == "LAGOON_DBAAS_ENVIRONMENT_TYPES") | "\(.value)"'))
fi
if [ ! -z "$LAGOON_ENVIRONMENT_VARIABLES" ]; then
  TEMP_LAGOON_DBAAS_ENVIRONMENT_TYPES=($(echo $LAGOON_ENVIRONMENT_VARIABLES | jq -r '.[] | select(.name == "LAGOON_DBAAS_ENVIRONMENT_TYPES") | "\(.value)"'))
  if [ ! -z $TEMP_LAGOON_DBAAS_ENVIRONMENT_TYPES ]; then
    LAGOON_DBAAS_ENVIRONMENT_TYPES=$TEMP_LAGOON_DBAAS_ENVIRONMENT_TYPES
  fi
fi
set -x

for COMPOSE_SERVICE in "${COMPOSE_SERVICES[@]}"
do
  # The name of the service can be overridden, if not we use the actual servicename
  SERVICE_NAME=$(cat $DOCKER_COMPOSE_YAML | shyaml get-value services.$COMPOSE_SERVICE.labels.lagoon\\.name default)
  if [ "$SERVICE_NAME" == "default" ]; then
    SERVICE_NAME=$COMPOSE_SERVICE
  fi

  # Load the servicetype. If it's "none" we will not care about this service at all
  SERVICE_TYPE=$(cat $DOCKER_COMPOSE_YAML | shyaml get-value services.$COMPOSE_SERVICE.labels.lagoon\\.type custom)

  # Allow the servicetype to be overriden by environment in .lagoon.yml
  ENVIRONMENT_SERVICE_TYPE_OVERRIDE=$(cat .lagoon.yml | shyaml get-value environments.${BRANCH//./\\.}.types.$SERVICE_NAME false)
  if [ ! $ENVIRONMENT_SERVICE_TYPE_OVERRIDE == "false" ]; then
    SERVICE_TYPE=$ENVIRONMENT_SERVICE_TYPE_OVERRIDE
  fi

  if [ ! -z "$LAGOON_SERVICE_TYPES" ]; then
    IFS=',' read -ra LAGOON_SERVICE_TYPES_SPLIT <<< "$LAGOON_SERVICE_TYPES"
    for LAGOON_SERVICE_TYPE in "${LAGOON_SERVICE_TYPES_SPLIT[@]}"
    do
      IFS=':' read -ra LAGOON_SERVICE_TYPE_SPLIT <<< "$LAGOON_SERVICE_TYPE"
      if [ "${LAGOON_SERVICE_TYPE_SPLIT[0]}" == "$SERVICE_NAME" ]; then
        SERVICE_TYPE=${LAGOON_SERVICE_TYPE_SPLIT[1]}
      fi
    done
  fi

  # functions used to check dbaas providers
  ####
  function checkDBaaSHealth() {
    response_code=$(curl --write-out "%{http_code}\n" --silent --output /dev/null "${DBAAS_OPERATOR_HTTP}/healthz")
    if [ "$response_code" == "200" ]; then
      return 0
    else
      return 1
    fi
  }

  function checkDBaaSProvider() {
    response_json=$(curl --silent "${DBAAS_OPERATOR_HTTP}/$1/$2")
    response_found=$(echo ${response_json} | jq -r '.result.found')
    response_error=$(echo ${response_json} | jq -r '.error')
    if [ "${response_error}" == "null" ]; then
      return 0
    else
      echo $response_error 1>&2
      return 1
    fi
  }

  function getDBaaSEnvironment() {
    dbaas_environment=$(cat $DOCKER_COMPOSE_YAML | shyaml get-value services.$COMPOSE_SERVICE.labels.lagoon\\.$1\\.environment "${ENVIRONMENT_TYPE}")
    # Allow the dbaas shared servicebroker plan to be overriden by environment in .lagoon.yml
    environment_dbaas_override=$(cat .lagoon.yml | shyaml get-value environments.${BRANCH//./\\.}.overrides.$SERVICE_NAME.$1\\.environment false)
    if [ ! $environment_dbaas_override == "false" ]; then
      dbaas_environment=$environment_dbaas_override
    fi
    # If we have a dbaas environment type override in the api, consume it here
    if [ ! -z "$LAGOON_DBAAS_ENVIRONMENT_TYPES" ]; then
      IFS=',' read -ra LAGOON_DBAAS_ENVIRONMENT_TYPES_SPLIT <<< "$LAGOON_DBAAS_ENVIRONMENT_TYPES"
      for LAGOON_DBAAS_ENVIRONMENT_TYPE in "${LAGOON_DBAAS_ENVIRONMENT_TYPES_SPLIT[@]}"
      do
        IFS=':' read -ra LAGOON_DBAAS_ENVIRONMENT_TYPE_SPLIT <<< "$LAGOON_DBAAS_ENVIRONMENT_TYPE"
        if [ "${LAGOON_DBAAS_ENVIRONMENT_TYPE_SPLIT[0]}" == "$SERVICE_NAME" ]; then
          dbaas_environment=${LAGOON_DBAAS_ENVIRONMENT_TYPE_SPLIT[1]}
        fi
      done
    fi
    echo $dbaas_environment
  }
  ####

  # Previous versions of Lagoon used "python-ckandatapusher", this should be mapped to "python"
  if [[ "$SERVICE_TYPE" == "python-ckandatapusher" ]]; then
    SERVICE_TYPE="python"
  fi

  if [[ "${CAPABILITIES[@]}" =~ "backup.appuio.ch/v1alpha1/PreBackupPod" ]]; then
    if [[ "$SERVICE_TYPE" == "opensearch" ]] || [[ "$SERVICE_TYPE" == "elasticsearch" ]]; then
      if kubectl -n ${NAMESPACE} get prebackuppods.backup.appuio.ch "${SERVICE_NAME}-prebackuppod" &> /dev/null; then
        kubectl -n ${NAMESPACE} delete prebackuppods.backup.appuio.ch "${SERVICE_NAME}-prebackuppod"
      fi
    fi
  fi

  # "mariadb" is a meta service, which allows lagoon to decide itself which of the services to use:
  # - mariadb-single (a single mariadb pod)
  # - mariadb-dbaas (use the dbaas shared operator)
  if [ "$SERVICE_TYPE" == "mariadb" ]; then
    # if there is already a service existing with the service_name we assume that for this project there has been a
    # mariadb-single deployed (probably from the past where there was no mariadb-shared yet, or mariadb-dbaas) and use that one
    if kubectl -n ${NAMESPACE} get service "$SERVICE_NAME" &> /dev/null; then
      SERVICE_TYPE="mariadb-single"
    elif checkDBaaSHealth; then
      # check if the dbaas operator responds to a health check
      # if it does, then check if the dbaas operator has a provider matching the provider type that is expected
      if checkDBaaSProvider mariadb $(getDBaaSEnvironment mariadb-dbaas); then
        SERVICE_TYPE="mariadb-dbaas"
      else
        SERVICE_TYPE="mariadb-single"
      fi
    elif [[ "${CAPABILITIES[@]}" =~ "mariadb.amazee.io/v1/MariaDBConsumer" ]] && ! checkDBaaSHealth ; then
      # check if this cluster supports the default one, if not we assume that this cluster is not capable of shared mariadbs and we use a mariadb-single
      # real basic check to see if the mariadbconsumer exists as a kind
      SERVICE_TYPE="mariadb-dbaas"
    else
      SERVICE_TYPE="mariadb-single"
    fi

  fi

  # Previous versions of Lagoon supported "mariadb-shared", this has been superseeded by "mariadb-dbaas"
  if [[ "$SERVICE_TYPE" == "mariadb-shared" ]]; then
    SERVICE_TYPE="mariadb-dbaas"
  fi

  if [[ "$SERVICE_TYPE" == "mariadb-dbaas" ]]; then
    # Default plan is the enviroment type
    DBAAS_ENVIRONMENT=$(getDBaaSEnvironment mariadb-dbaas)

    MAP_SERVICE_NAME_TO_DBAAS_ENVIRONMENT["${SERVICE_NAME}"]="${DBAAS_ENVIRONMENT}"
  fi

  # "postgres" is a meta service, which allows lagoon to decide itself which of the services to use:
  # - postgres-single (a single postgres pod)
  # - postgres-dbaas (use the dbaas shared operator)
  if [ "$SERVICE_TYPE" == "postgres" ]; then
    # if there is already a service existing with the service_name we assume that for this project there has been a
    # postgres-single deployed (probably from the past where there was no postgres-shared yet, or postgres-dbaas) and use that one
    if kubectl -n ${NAMESPACE} get service "$SERVICE_NAME" &> /dev/null; then
      SERVICE_TYPE="postgres-single"
    elif checkDBaaSHealth; then
      # check if the dbaas operator responds to a health check
      # if it does, then check if the dbaas operator has a provider matching the provider type that is expected
      if checkDBaaSProvider postgres $(getDBaaSEnvironment postgres-dbaas); then
        SERVICE_TYPE="postgres-dbaas"
      else
        SERVICE_TYPE="postgres-single"
      fi
    # heck if this cluster supports the default one, if not we assume that this cluster is not capable of shared PostgreSQL and we use a postgres-single
    # real basic check to see if the postgreSQLConsumer exists as a kind
    elif [[ "${CAPABILITIES[@]}" =~ "postgres.amazee.io/v1/PostgreSQLConsumer" ]] && ! checkDBaaSHealth; then
      SERVICE_TYPE="postgres-dbaas"
    else
      SERVICE_TYPE="postgres-single"
    fi

  fi

  # Previous versions of Lagoon supported "postgres-shared", this has been superseeded by "postgres-dbaas"
  if [[ "$SERVICE_TYPE" == "postgres-shared" ]]; then
    SERVICE_TYPE="postgres-dbaas"
  fi

  if [[ "$SERVICE_TYPE" == "postgres-dbaas" ]]; then
    # Default plan is the enviroment type
    DBAAS_ENVIRONMENT=$(getDBaaSEnvironment postgres-dbaas)

    MAP_SERVICE_NAME_TO_DBAAS_ENVIRONMENT["${SERVICE_NAME}"]="${DBAAS_ENVIRONMENT}"
  fi

  # "mongo" is a meta service, which allows lagoon to decide itself which of the services to use:
  # - mongodb-single (a single mongodb pod)
  # - mongodb-dbaas (use the dbaas shared operator)
  if [ "$SERVICE_TYPE" == "mongo" ]; then
    # if there is already a service existing with the service_name we assume that for this project there has been a
    # mongodb-single deployed (probably from the past where there was no mongodb-shared yet, or mongodb-dbaas) and use that one
    if kubectl -n ${NAMESPACE} get service "$SERVICE_NAME" &> /dev/null; then
      SERVICE_TYPE="mongodb-single"
    elif checkDBaaSHealth; then
      # check if the dbaas operator responds to a health check
      # if it does, then check if the dbaas operator has a provider matching the provider type that is expected
      if checkDBaaSProvider mongodb $(getDBaaSEnvironment mongodb-dbaas); then
        SERVICE_TYPE="mongodb-dbaas"
      else
        SERVICE_TYPE="mongodb-single"
      fi
    # heck if this cluster supports the default one, if not we assume that this cluster is not capable of shared MongoDB and we use a mongodb-single
    # real basic check to see if the MongoDBConsumer exists as a kind
    elif [[ "${CAPABILITIES[@]}" =~ "mongodb.amazee.io/v1/MongoDBConsumer" ]] && ! checkDBaaSHealth; then
      SERVICE_TYPE="mongodb-dbaas"
    else
      SERVICE_TYPE="mongodb-single"
    fi

  fi

  # Previous versions of Lagoon supported "mongo-shared", this has been superseeded by "mongodb-dbaas"
  if [[ "$SERVICE_TYPE" == "mongo-shared" ]]; then
    SERVICE_TYPE="mongodb-dbaas"
  fi

  if [[ "$SERVICE_TYPE" == "mongodb-dbaas" ]]; then
    DBAAS_ENVIRONMENT=$(getDBaaSEnvironment mongodb-dbaas)

    MAP_SERVICE_NAME_TO_DBAAS_ENVIRONMENT["${SERVICE_NAME}"]="${DBAAS_ENVIRONMENT}"
  fi

  if [ "$SERVICE_TYPE" == "none" ]; then
    continue
  fi

  # For DeploymentConfigs with multiple Services inside (like nginx-php), we allow to define the service type of within the
  # deploymentconfig via lagoon.deployment.servicetype. If this is not set we use the Compose Service Name
  DEPLOYMENT_SERVICETYPE=$(cat $DOCKER_COMPOSE_YAML | shyaml get-value services.$COMPOSE_SERVICE.labels.lagoon\\.deployment\\.servicetype default)
  if [ "$DEPLOYMENT_SERVICETYPE" == "default" ]; then
    DEPLOYMENT_SERVICETYPE=$COMPOSE_SERVICE
  fi

  # The ImageName is the same as the Name of the Docker Compose ServiceName
  IMAGE_NAME=$COMPOSE_SERVICE

  # Do not handle images for shared services
  if  [[ "$SERVICE_TYPE" != "mariadb-dbaas" ]] &&
      [[ "$SERVICE_TYPE" != "mariadb-shared" ]] &&
      [[ "$SERVICE_TYPE" != "postgres-shared" ]] &&
      [[ "$SERVICE_TYPE" != "postgres-dbaas" ]] &&
      [[ "$SERVICE_TYPE" != "mongodb-dbaas" ]] &&
      [[ "$SERVICE_TYPE" != "mongodb-shared" ]]; then
    # Generate List of Images to build
    IMAGES+=("${IMAGE_NAME}")
  fi

  # Map Deployment ServiceType to the ImageName
  MAP_DEPLOYMENT_SERVICETYPE_TO_IMAGENAME["${SERVICE_NAME}:${DEPLOYMENT_SERVICETYPE}"]="${IMAGE_NAME}"

  # Create an array with all Service Names and Types if it does not exist yet
  if [[ ! " ${SERVICE_TYPES[@]} " =~ " ${SERVICE_NAME}:${SERVICE_TYPE} " ]]; then
    SERVICE_TYPES+=("${SERVICE_NAME}:${SERVICE_TYPE}")
  fi

  # ServiceName and Type to Original Service Name Mapping, but only once per Service name and Type,
  # as we have original services that appear twice (like in the case of nginx-php)
  if [[ ! "${MAP_SERVICE_TYPE_TO_COMPOSE_SERVICE["${SERVICE_NAME}:${SERVICE_TYPE}"]+isset}" ]]; then
    MAP_SERVICE_TYPE_TO_COMPOSE_SERVICE["${SERVICE_NAME}:${SERVICE_TYPE}"]="${COMPOSE_SERVICE}"
  fi

  # ServiceName to ImageName mapping, but only once as we have original services that appear twice (like in the case of nginx-php)
  # these will be handled via MAP_DEPLOYMENT_SERVICETYPE_TO_IMAGENAME
  if [[ ! "${MAP_SERVICE_NAME_TO_IMAGENAME["${SERVICE_NAME}"]+isset}" ]]; then
    MAP_SERVICE_NAME_TO_IMAGENAME["${SERVICE_NAME}"]="${IMAGE_NAME}"
  fi

done

set +x
currentStepEnd="$(date +"%Y-%m-%d %H:%M:%S")"
patchBuildStep "${buildStartTime}" "${buildStartTime}" "${currentStepEnd}" "${NAMESPACE}" "configureVars" "Configure Variables" "false"
previousStepEnd=${currentStepEnd}
beginBuildStep "Image Builds" "buildingImages"
set -x
##############################################
### CACHE IMAGE LIST GENERATION
##############################################

LAGOON_CACHE_BUILD_ARGS=()
readarray LAGOON_CACHE_BUILD_ARGS < <(kubectl -n ${NAMESPACE} get deployments -o yaml -l 'lagoon.sh/service' | yq e '.items[].spec.template.spec.containers[].image | capture("^(?P<image>.+\/.+\/.+\/(?P<name>.+)\@.*)$") | "LAGOON_CACHE_" + .name + "=" + .image' -)



##############################################
### BUILD IMAGES
##############################################

set +x # reduce noise in build logs
# Get the pre-rollout and post-rollout vars
  if [ ! -z "$LAGOON_PROJECT_VARIABLES" ]; then
    LAGOON_PREROLLOUT_DISABLED=($(echo $LAGOON_PROJECT_VARIABLES | jq -r '.[] | select(.name == "LAGOON_PREROLLOUT_DISABLED") | "\(.value)"'))
    LAGOON_POSTROLLOUT_DISABLED=($(echo $LAGOON_PROJECT_VARIABLES | jq -r '.[] | select(.name == "LAGOON_POSTROLLOUT_DISABLED") | "\(.value)"'))
  fi
  if [ ! -z "$LAGOON_ENVIRONMENT_VARIABLES" ]; then
    TEMP_LAGOON_PREROLLOUT_DISABLED=($(echo $LAGOON_ENVIRONMENT_VARIABLES | jq -r '.[] | select(.name == "LAGOON_PREROLLOUT_DISABLED") | "\(.value)"'))
    TEMP_LAGOON_POSTROLLOUT_DISABLED=($(echo $LAGOON_ENVIRONMENT_VARIABLES | jq -r '.[] | select(.name == "LAGOON_POSTROLLOUT_DISABLED") | "\(.value)"'))
    if [ ! -z $TEMP_LAGOON_PREROLLOUT_DISABLED ]; then
      LAGOON_PREROLLOUT_DISABLED=$TEMP_LAGOON_PREROLLOUT_DISABLED
    fi
    if [ ! -z $TEMP_LAGOON_POSTROLLOUT_DISABLED ]; then
      LAGOON_POSTROLLOUT_DISABLED=$TEMP_LAGOON_POSTROLLOUT_DISABLED
    fi
  fi
set -x

# we only need to build images for pullrequests and branches
if [[ "$BUILD_TYPE" == "pullrequest"  ||  "$BUILD_TYPE" == "branch" ]]; then

  BUILD_ARGS=()

  set +x # reduce noise in build logs
  # Add environment variables from lagoon API as build args
  if [ ! -z "$LAGOON_PROJECT_VARIABLES" ]; then
    echo "LAGOON_PROJECT_VARIABLES are available from the API"
    # multiline/spaced variables seem to break when being added from the API.
    # this changes the way it works to create the variable in a similar way to how they are injected below
    LAGOON_ENV_VARS=$(echo $LAGOON_PROJECT_VARIABLES | jq -r '.[] | select(.scope == "build" or .scope == "global") | "\(.name)"')
    for LAGOON_ENV_VAR in $LAGOON_ENV_VARS
    do
      BUILD_ARGS+=(--build-arg $(echo $LAGOON_ENV_VAR)="$(echo $LAGOON_PROJECT_VARIABLES | jq -r '.[] | select(.scope == "build" or .scope == "global") | select(.name == "'$LAGOON_ENV_VAR'") | "\(.value)"')")
    done
  fi
  if [ ! -z "$LAGOON_ENVIRONMENT_VARIABLES" ]; then
    echo "LAGOON_ENVIRONMENT_VARIABLES are available from the API"
    # multiline/spaced variables seem to break when being added from the API.
    # this changes the way it works to create the variable in a similar way to how they are injected below
    LAGOON_ENV_VARS=$(echo $LAGOON_ENVIRONMENT_VARIABLES | jq -r '.[] | select(.scope == "build" or .scope == "global") | "\(.name)"')
    for LAGOON_ENV_VAR in $LAGOON_ENV_VARS
    do
      BUILD_ARGS+=(--build-arg $(echo $LAGOON_ENV_VAR)="$(echo $LAGOON_ENVIRONMENT_VARIABLES | jq -r '.[] | select(.scope == "build" or .scope == "global") | select(.name == "'$LAGOON_ENV_VAR'") | "\(.value)"')")
    done
  fi
  set -x

  BUILD_ARGS+=(--build-arg IMAGE_REPO="${CI_OVERRIDE_IMAGE_REPO}")
  BUILD_ARGS+=(--build-arg LAGOON_PROJECT="${PROJECT}")
  BUILD_ARGS+=(--build-arg LAGOON_ENVIRONMENT="${ENVIRONMENT}")
  BUILD_ARGS+=(--build-arg LAGOON_ENVIRONMENT_TYPE="${ENVIRONMENT_TYPE}")
  BUILD_ARGS+=(--build-arg LAGOON_BUILD_TYPE="${BUILD_TYPE}")
  BUILD_ARGS+=(--build-arg LAGOON_GIT_SOURCE_REPOSITORY="${SOURCE_REPOSITORY}")
  BUILD_ARGS+=(--build-arg LAGOON_KUBERNETES="${KUBERNETES}")

  # Add in the cache args
  for value in "${LAGOON_CACHE_BUILD_ARGS[@]}"
  do
        BUILD_ARGS+=(--build-arg $value)
  done

  set +x
  BUILD_ARGS+=(--build-arg LAGOON_SSH_PRIVATE_KEY="${SSH_PRIVATE_KEY}")
  set -x

  if [ "$BUILD_TYPE" == "branch" ]; then
    BUILD_ARGS+=(--build-arg LAGOON_GIT_SHA="${LAGOON_GIT_SHA}")
    BUILD_ARGS+=(--build-arg LAGOON_GIT_BRANCH="${BRANCH}")
  fi

  if [ "$BUILD_TYPE" == "pullrequest" ]; then
    BUILD_ARGS+=(--build-arg LAGOON_GIT_SHA="${LAGOON_GIT_SHA}")
    BUILD_ARGS+=(--build-arg LAGOON_PR_HEAD_BRANCH="${PR_HEAD_BRANCH}")
    BUILD_ARGS+=(--build-arg LAGOON_PR_HEAD_SHA="${PR_HEAD_SHA}")
    BUILD_ARGS+=(--build-arg LAGOON_PR_BASE_BRANCH="${PR_BASE_BRANCH}")
    BUILD_ARGS+=(--build-arg LAGOON_PR_BASE_SHA="${PR_BASE_SHA}")
    BUILD_ARGS+=(--build-arg LAGOON_PR_TITLE="${PR_TITLE}")
    BUILD_ARGS+=(--build-arg LAGOON_PR_NUMBER="${PR_NUMBER}")
  fi

  # Add in random data as per https://github.com/uselagoon/lagoon/issues/2246
  BUILD_ARGS+=(--build-arg LAGOON_BUILD_NAME="${LAGOON_BUILD_NAME}")

  for IMAGE_NAME in "${IMAGES[@]}"
  do

    DOCKERFILE=$(cat $DOCKER_COMPOSE_YAML | shyaml get-value services.$IMAGE_NAME.build.dockerfile false)

    # allow to overwrite build dockerfile for this environment and service
    ENVIRONMENT_DOCKERFILE_OVERRIDE=$(cat .lagoon.yml | shyaml get-value environments.${BRANCH//./\\.}.overrides.$IMAGE_NAME.build.dockerfile false)
    if [ ! $ENVIRONMENT_DOCKERFILE_OVERRIDE == "false" ]; then
      DOCKERFILE=$ENVIRONMENT_DOCKERFILE_OVERRIDE
    fi

    if [ $DOCKERFILE == "false" ]; then
      # No Dockerfile defined, assuming to download the Image directly

      PULL_IMAGE=$(cat $DOCKER_COMPOSE_YAML | shyaml get-value services.$IMAGE_NAME.image false)
      if [ $PULL_IMAGE == "false" ]; then
        echo "No Dockerfile or Image for service ${IMAGE_NAME} defined"; exit 1;
      fi

      # allow to overwrite image that we pull
      OVERRIDE_IMAGE=$(cat $DOCKER_COMPOSE_YAML | shyaml get-value services.$IMAGE_NAME.labels.lagoon\\.image false)

      # allow to overwrite image that we pull for this environment and service
      ENVIRONMENT_IMAGE_OVERRIDE=$(cat .lagoon.yml | shyaml get-value environments.${BRANCH//./\\.}.overrides.$IMAGE_NAME.image false)
      if [ ! $ENVIRONMENT_IMAGE_OVERRIDE == "false" ]; then
        OVERRIDE_IMAGE=$ENVIRONMENT_IMAGE_OVERRIDE
      fi

      if [ ! $OVERRIDE_IMAGE == "false" ]; then
        # expand environment variables from ${OVERRIDE_IMAGE}
        PULL_IMAGE=$(echo "${OVERRIDE_IMAGE}" | envsubst)
      fi

      # if the image just is an image name (like "alpine") we prefix it with `libary/` as the imagecache does not understand
      # the magic `alpine` images
      if [[ ! "$PULL_IMAGE" =~ "/" ]]; then
        PULL_IMAGE="library/$PULL_IMAGE"
      fi

      # Add the images we should pull to the IMAGES_PULL array, they will later be tagged from dockerhub
      IMAGES_PULL["${IMAGE_NAME}"]="${PULL_IMAGE}"

    else
      # Dockerfile defined, load the context and build it

      # We need the Image Name uppercase sometimes, so we create that here
      IMAGE_NAME_UPPERCASE=$(echo "$IMAGE_NAME" | tr '[:lower:]' '[:upper:]')


      # To prevent clashes of ImageNames during parallel builds, we give all Images a Temporary name
      TEMPORARY_IMAGE_NAME="${NAMESPACE}-${IMAGE_NAME}"

      BUILD_CONTEXT=$(cat $DOCKER_COMPOSE_YAML | shyaml get-value services.$IMAGE_NAME.build.context .)

      # Check to see if this service uses a build target
      BUILD_TARGET=$(cat $DOCKER_COMPOSE_YAML | shyaml get-value services.$IMAGE_NAME.build.target false)

      # allow to overwrite build context for this environment and service
      ENVIRONMENT_BUILD_CONTEXT_OVERRIDE=$(cat .lagoon.yml | shyaml get-value environments.${BRANCH//./\\.}.overrides.$IMAGE_NAME.build.context false)
      if [ ! $ENVIRONMENT_BUILD_CONTEXT_OVERRIDE == "false" ]; then
        BUILD_CONTEXT=$ENVIRONMENT_BUILD_CONTEXT_OVERRIDE
      fi

      if [ ! -f $BUILD_CONTEXT/$DOCKERFILE ]; then
        echo "defined Dockerfile $DOCKERFILE for service $IMAGE_NAME not found"; exit 1;
      fi

      set +x # reduce noise in build logs
      # Decide whether to use BuildKit for Docker builds - disabled by default.
      DOCKER_BUILDKIT=0

      if [ ! -z "$LAGOON_PROJECT_VARIABLES" ]; then
        DOCKER_BUILDKIT=($(echo $LAGOON_PROJECT_VARIABLES | jq -r '.[] | select(.scope == "build") | select(.name == "DOCKER_BUILDKIT") | "\(.value)"'))
      fi
      if [ ! -z "$LAGOON_ENVIRONMENT_VARIABLES" ]; then
        TEMP_DOCKER_BUILDKIT=($(echo $LAGOON_ENVIRONMENT_VARIABLES | jq -r '.[] | select(.scope == "build") | select(.name == "DOCKER_BUILDKIT") | "\(.value)"'))
        if [ ! -z $TEMP_DOCKER_BUILDKIT ]; then
          DOCKER_BUILDKIT=$TEMP_DOCKER_BUILDKIT
        fi
      fi

      case "$DOCKER_BUILDKIT" in
        1|t|T|true|TRUE|True)
          DOCKER_BUILDKIT=1
          echo "Using BuildKit for $DOCKERFILE";
        ;;
        *)
          DOCKER_BUILDKIT=0
        ;;
      esac
      set -x

      . /kubectl-build-deploy/scripts/exec-build.sh

      # Keep a list of the images we have built, as we need to push them to the OpenShift Registry later
      IMAGES_BUILD["${IMAGE_NAME}"]="${TEMPORARY_IMAGE_NAME}"

      # adding the build image to the list of arguments passed into the next image builds
      BUILD_ARGS+=(--build-arg ${IMAGE_NAME_UPPERCASE}_IMAGE=${TEMPORARY_IMAGE_NAME})
    fi

  done

fi

set +x
# print information about built image sizes
function printBytes {
    local -i bytes=$1;
    echo "$(( (bytes + 1000000)/1000000 ))MB"
}
if [[ "${IMAGES_BUILD[@]}" ]]; then
  echo "##############################################"
  echo "Built image sizes:"
  echo "##############################################"
fi
for IMAGE_NAME in "${!IMAGES_BUILD[@]}"
do
  TEMPORARY_IMAGE_NAME="${IMAGES_BUILD[${IMAGE_NAME}]}"
  echo -e "Image ${TEMPORARY_IMAGE_NAME}\t\t$(printBytes $(docker inspect ${TEMPORARY_IMAGE_NAME} | jq -r '.[0].Size'))"
done
set -x

set +x
currentStepEnd="$(date +"%Y-%m-%d %H:%M:%S")"
patchBuildStep "${buildStartTime}" "${previousStepEnd}" "${currentStepEnd}" "${NAMESPACE}" "imageBuildComplete" "Image Builds" "false"
previousStepEnd=${currentStepEnd}
beginBuildStep "Pre-Rollout Tasks" "runningPreRolloutTasks"
set -x

##############################################
### RUN PRE-ROLLOUT tasks defined in .lagoon.yml
##############################################

if [ "${LAGOON_PREROLLOUT_DISABLED}" != "true" ]; then
    build-deploy-tool tasks pre-rollout
else
  echo "pre-rollout tasks are currently disabled LAGOON_PREROLLOUT_DISABLED is set to true"
  set +x
  currentStepEnd="$(date +"%Y-%m-%d %H:%M:%S")"
  patchBuildStep "${buildStartTime}" "${previousStepEnd}" "${currentStepEnd}" "${NAMESPACE}" "preRolloutsCompleted" "Pre-Rollout Tasks" "false"
  set -x
fi

set +x
currentStepEnd="$(date +"%Y-%m-%d %H:%M:%S")"
previousStepEnd=${currentStepEnd}
beginBuildStep "Service Configuration Phase 1" "serviceConfigurationPhase1"
set -x


##############################################
### CONFIGURE SERVICES, AUTOGENERATED ROUTES AND DBAAS CONFIG
##############################################

YAML_FOLDER="/kubectl-build-deploy/lagoon/services-routes"
mkdir -p $YAML_FOLDER

# BC for routes.insecure, which is now called routes.autogenerate.insecure
BC_ROUTES_AUTOGENERATE_INSECURE=$(cat .lagoon.yml | shyaml get-value routes.insecure false)
if [ ! $BC_ROUTES_AUTOGENERATE_INSECURE == "false" ]; then
  echo "=== routes.insecure is now defined in routes.autogenerate.insecure, pleae update your .lagoon.yml file"
  # update the .lagoon.yml with the new location for build-deploy-tool to read
  yq3 write -i -- .lagoon.yml 'routes.autogenerate.insecure' $BC_ROUTES_AUTOGENERATE_INSECURE
fi

touch /kubectl-build-deploy/values.yaml

yq3 write -i -- /kubectl-build-deploy/values.yaml 'project' $PROJECT
yq3 write -i -- /kubectl-build-deploy/values.yaml 'environment' $ENVIRONMENT
yq3 write -i -- /kubectl-build-deploy/values.yaml 'environmentType' $ENVIRONMENT_TYPE
yq3 write -i -- /kubectl-build-deploy/values.yaml 'namespace' $NAMESPACE
yq3 write -i -- /kubectl-build-deploy/values.yaml 'gitSha' $LAGOON_GIT_SHA
yq3 write -i -- /kubectl-build-deploy/values.yaml 'buildType' $BUILD_TYPE
yq3 write -i -- /kubectl-build-deploy/values.yaml 'kubernetes' $KUBERNETES
yq3 write -i -- /kubectl-build-deploy/values.yaml 'lagoonVersion' $LAGOON_VERSION
if [ "$ADMIN_LAGOON_FEATURE_FLAG_CONTAINER_MEMORY_LIMIT" ]; then
  yq3 write -i -- /kubectl-build-deploy/values.yaml 'resources.limits.memory' "$ADMIN_LAGOON_FEATURE_FLAG_CONTAINER_MEMORY_LIMIT"
fi
if [ "$ADMIN_LAGOON_FEATURE_FLAG_EPHEMERAL_STORAGE_REQUESTS" ]; then
  yq3 write -i -- /kubectl-build-deploy/values.yaml 'resources.requests.ephemeral-storage' "$ADMIN_LAGOON_FEATURE_FLAG_EPHEMERAL_STORAGE_REQUESTS"
fi
if [ "$ADMIN_LAGOON_FEATURE_FLAG_EPHEMERAL_STORAGE_LIMIT" ]; then
  yq3 write -i -- /kubectl-build-deploy/values.yaml 'resources.limits.ephemeral-storage' "$ADMIN_LAGOON_FEATURE_FLAG_EPHEMERAL_STORAGE_LIMIT"
fi
# check for ROOTLESS_WORKLOAD feature flag, disabled by default

set +x
if [ "$(featureFlag ROOTLESS_WORKLOAD)" = enabled ]; then
	yq3 merge -ix -- /kubectl-build-deploy/values.yaml /kubectl-build-deploy/rootless.values.yaml
fi
if [ "$(featureFlag FS_ON_ROOT_MISMATCH)" = enabled ]; then
	yq3 write -i -- /kubectl-build-deploy/values.yaml 'podSecurityContext.fsGroupChangePolicy' "OnRootMismatch"
fi
if [ "${SCC_CHECK}" != "false" ]; then
  # openshift permissions are different, this is to set the fsgroup to the supplemental group from the openshift annotations
  # this applies it to all deployments in this environment because we don't isolate by service type its applied to all
  OPENSHIFT_SUPPLEMENTAL_GROUP=$(kubectl get namespace ${NAMESPACE} -o json | jq -r '.metadata.annotations."openshift.io/sa.scc.supplemental-groups"' | cut -c -10)
  echo "Setting openshift fsGroup to ${OPENSHIFT_SUPPLEMENTAL_GROUP}"
  yq3 write -i -- /kubectl-build-deploy/values.yaml 'podSecurityContext.fsGroup' $OPENSHIFT_SUPPLEMENTAL_GROUP
fi
set -x


echo -e "\
imagePullSecrets:\n\
" >> /kubectl-build-deploy/values.yaml

for REGISTRY_SECRET in "${REGISTRY_SECRETS[@]}"
do
  echo -e "\
  - name: "${REGISTRY_SECRET}"\n\
" >> /kubectl-build-deploy/values.yaml
done

echo -e "\
LAGOON_PROJECT=${PROJECT}\n\
LAGOON_ENVIRONMENT=${ENVIRONMENT}\n\
LAGOON_ENVIRONMENT_TYPE=${ENVIRONMENT_TYPE}\n\
LAGOON_GIT_SHA=${LAGOON_GIT_SHA}\n\
LAGOON_KUBERNETES=${KUBERNETES}\n\
" >> /kubectl-build-deploy/values.env

# DEPRECATED: will be removed with Lagoon 3.0.0
# LAGOON_GIT_SAFE_BRANCH is pointing to the enviornment name, therefore also is filled if this environment
# is created by a PR or Promote workflow. This technically wrong, therefore will be removed
echo -e "\
LAGOON_GIT_SAFE_BRANCH=${ENVIRONMENT}\n\
" >> /kubectl-build-deploy/values.env

if [ "$BUILD_TYPE" == "branch" ]; then
  yq3 write -i -- /kubectl-build-deploy/values.yaml 'branch' $BRANCH

  echo -e "\
LAGOON_GIT_BRANCH=${BRANCH}\n\
" >> /kubectl-build-deploy/values.env
fi

if [ "$BUILD_TYPE" == "pullrequest" ]; then
  yq3 write -i -- /kubectl-build-deploy/values.yaml 'prHeadBranch' "$PR_HEAD_BRANCH"
  yq3 write -i -- /kubectl-build-deploy/values.yaml 'prBaseBranch' "$PR_BASE_BRANCH"
  yq3 write -i -- /kubectl-build-deploy/values.yaml 'prTitle' "$PR_TITLE"
  yq3 write -i -- /kubectl-build-deploy/values.yaml 'prNumber' "$PR_NUMBER"

  echo -e "\
LAGOON_PR_HEAD_BRANCH=${PR_HEAD_BRANCH}\n\
LAGOON_PR_BASE_BRANCH=${PR_BASE_BRANCH}\n\
LAGOON_PR_TITLE=${PR_TITLE}\n\
LAGOON_PR_NUMBER=${PR_NUMBER}\n\
" >> /kubectl-build-deploy/values.env
fi

set +x
currentStepEnd="$(date +"%Y-%m-%d %H:%M:%S")"
patchBuildStep "${buildStartTime}" "${previousStepEnd}" "${currentStepEnd}" "${NAMESPACE}" "serviceConfigurationComplete" "Service Configuration Phase 1" "false"
previousStepEnd=${currentStepEnd}
beginBuildStep "Service Configuration Phase 2" "serviceConfigurationPhase2"
set -x

##############################################
### CUSTOM FASTLY API SECRETS .lagoon.yml
##############################################

# if a customer is using their own fastly configuration, then they can define their api token and platform tls configuration ID in the .lagoon.yml file
# this will get created as a `kind: Secret` in kubernetes so that created ingresses will be able to use this secret to talk to the fastly api.
#
# in this example, the customer needs to add a build envvar called `FASTLY_API_TOKEN` and then populates the .lagoon.yml file with something like this
#
# fastly:
#   api-secrets:
#     - name: customer
#       apiTokenVariableName: FASTLY_API_TOKEN
#       platformTLSConfiguration: A1bcEdFgH12eD242Sds
#
# then the build process will attempt to check the lagoon variables for one called `FASTLY_API_TOKEN` and will use the value of this variable when creating the
# `kind: Secret` in kubernetes
#
# support for multiple api-secrets is possible in the instance that a customer uses 2 separate services in different accounts in the one project

## any fastly api secrets will be prefixed with this, so that we always add this to whatever the customer provides
FASTLY_API_SECRET_PREFIX="fastly-api-"

FASTLY_API_SECRETS_COUNTER=0
FASTLY_API_SECRETS=()
set +x # reduce noise in build logs
if [ -n "$(cat .lagoon.yml | shyaml keys fastly.api-secrets.$FASTLY_API_SECRETS_COUNTER 2> /dev/null)" ]; then
  while [ -n "$(cat .lagoon.yml | shyaml get-value fastly.api-secrets.$FASTLY_API_SECRETS_COUNTER 2> /dev/null)" ]; do
    FASTLY_API_SECRET_NAME=$FASTLY_API_SECRET_PREFIX$(cat .lagoon.yml | shyaml get-value fastly.api-secrets.$FASTLY_API_SECRETS_COUNTER.name 2> /dev/null)
    if [ -z "$FASTLY_API_SECRET_NAME" ]; then
        echo -e "A fastly api secret was defined in the .lagoon.yml file, but no name could be found the .lagoon.yml\n\nPlease check if the name has been set correctly."
        exit 1
    fi
    FASTLY_API_TOKEN_VALUE=$(cat .lagoon.yml | shyaml get-value fastly.api-secrets.$FASTLY_API_SECRETS_COUNTER.apiTokenVariableName false)
    if [[ $FASTLY_API_TOKEN_VALUE == "false" ]]; then
      echo "No 'apiTokenVariableName' defined for fastly secret $FASTLY_API_SECRET_NAME"; exit 1;
    fi
    # if we have everything we need, we can proceed to logging in
    if [ $FASTLY_API_TOKEN_VALUE != "false" ]; then
      FASTLY_API_TOKEN=""
      # check if we have a password defined anywhere in the api first
      if [ ! -z "$LAGOON_PROJECT_VARIABLES" ]; then
        FASTLY_API_TOKEN=($(echo $LAGOON_PROJECT_VARIABLES | jq -r '.[] | select(.scope == "build" and .name == "'$FASTLY_API_TOKEN_VALUE'") | "\(.value)"'))
      fi
      if [ ! -z "$LAGOON_ENVIRONMENT_VARIABLES" ]; then
        TEMP_FASTLY_API_TOKEN=($(echo $LAGOON_ENVIRONMENT_VARIABLES | jq -r '.[] | select(.scope == "build" and .name == "'$FASTLY_API_TOKEN_VALUE'") | "\(.value)"'))
        if [ ! -z "$TEMP_FASTLY_API_TOKEN" ]; then
          FASTLY_API_TOKEN=$TEMP_FASTLY_API_TOKEN
        fi
      fi
      if [ -z "$FASTLY_API_TOKEN" ]; then
        echo -e "A fastly api secret was defined in the .lagoon.yml file, but no token could be found in the Lagoon API matching the variable name provided\n\nPlease check if the token has been set correctly."
        exit 1
      fi
    fi
    FASTLY_API_PLATFORMTLS_CONFIGURATION=$(cat .lagoon.yml | shyaml get-value fastly.api-secrets.$FASTLY_API_SECRETS_COUNTER.platformTLSConfiguration "")
    if [ -z "$FASTLY_API_PLATFORMTLS_CONFIGURATION" ]; then
      echo -e "A fastly api secret was defined in the .lagoon.yml file, but no platform tls configuration id could be found in the .lagoon.yml\n\nPlease check if the platform tls configuration id has been set correctly."
      exit 1
    fi

    # run the script to create the secrets
    . /kubectl-build-deploy/scripts/exec-fastly-api-secrets.sh

    let FASTLY_API_SECRETS_COUNTER=FASTLY_API_SECRETS_COUNTER+1
  done
fi
set -x

set +x # reduce noise in build logs
# FASTLY API SECRETS FROM LAGOON API VARIABLE
# Allow for defining fastly api secrets using lagoon api variables
# This accepts colon separated values like so `SECRET_NAME:FASTLY_API_TOKEN:FASTLY_PLATFORMTLS_CONFIGURATION_ID`, and multiple overrides
# separated by commas
# Example 1: examplecom:x1s8asfafasf7ssf:fa23rsdgsdgas
# ^^^ will create a kubernetes secret called `$FASTLY_API_SECRET_PREFIX-examplecom` with 2 data fields (one for api token, the other for platform tls id)
# populated with `x1s8asfafasf7ssf` and `fa23rsdgsdgas` for whichever field it should be
# and the name will get created with the prefix defined in `FASTLY_API_SECRET_PREFIX`
# Example 2: examplecom:x1s8asfafasf7ssf:fa23rsdgsdgas,example2com:fa23rsdgsdgas:x1s8asfafasf7ssf,example3com:fa23rsdgsdgas:x1s8asfafasf7ssf:example3com
if [ ! -z "$LAGOON_PROJECT_VARIABLES" ]; then
  LAGOON_FASTLY_API_SECRETS=($(echo $LAGOON_PROJECT_VARIABLES | jq -r '.[] | select(.name == "LAGOON_FASTLY_API_SECRETS") | "\(.value)"'))
fi
if [ ! -z "$LAGOON_ENVIRONMENT_VARIABLES" ]; then
  TEMP_LAGOON_FASTLY_API_SECRETS=($(echo $LAGOON_ENVIRONMENT_VARIABLES | jq -r '.[] | select(.name == "LAGOON_FASTLY_API_SECRETS") | "\(.value)"'))
  if [ ! -z $TEMP_LAGOON_FASTLY_API_SECRETS ]; then
    LAGOON_FASTLY_API_SECRETS=$TEMP_LAGOON_FASTLY_API_SECRETS
  fi
fi
if [ ! -z "$LAGOON_FASTLY_API_SECRETS" ]; then
  IFS=',' read -ra LAGOON_FASTLY_API_SECRETS_SPLIT <<< "$LAGOON_FASTLY_API_SECRETS"
  for LAGOON_FASTLY_API_SECRETS_DATA in "${LAGOON_FASTLY_API_SECRETS_SPLIT[@]}"
  do
    IFS=':' read -ra LAGOON_FASTLY_API_SECRET_SPLIT <<< "$LAGOON_FASTLY_API_SECRETS_DATA"
    if [ -z "${LAGOON_FASTLY_API_SECRET_SPLIT[0]}" ] || [ -z "${LAGOON_FASTLY_API_SECRET_SPLIT[1]}" ] || [ -z "${LAGOON_FASTLY_API_SECRET_SPLIT[2]}" ]; then
      echo -e "An override was defined in the lagoon API with LAGOON_FASTLY_API_SECRETS but was not structured correctly, the format should be NAME:FASTLY_API_TOKEN:FASTLY_PLATFORMTLS_CONFIGURATION_ID and comma separated for multiples"
      exit 1
    fi
    # the fastly api secret name will be created with the prefix that is defined above
    FASTLY_API_SECRET_NAME=$FASTLY_API_SECRET_PREFIX${LAGOON_FASTLY_API_SECRET_SPLIT[0]}
    FASTLY_API_TOKEN=${LAGOON_FASTLY_API_SECRET_SPLIT[1]}
    FASTLY_API_PLATFORMTLS_CONFIGURATION=${LAGOON_FASTLY_API_SECRET_SPLIT[2]}
    # run the script to create the secrets
    . /kubectl-build-deploy/scripts/exec-fastly-api-secrets.sh
  done
fi
set -x

set +x # reduce noise in build logs
# FASTLY SERVICE ID PER INGRESS OVERRIDE FROM LAGOON API VARIABLE
# Allow the fastly serviceid for specific ingress to be overridden by the lagoon API
# This accepts colon separated values like so `INGRESS_DOMAIN:FASTLY_SERVICE_ID:WATCH_STATUS:SECRET_NAME(OPTIONAL)`, and multiple overrides
# separated by commas
# Example 1: www.example.com:x1s8asfafasf7ssf:true
# ^^^ tells the ingress creation to use the service id x1s8asfafasf7ssf for ingress www.example.com, with the watch status of true
# Example 2: www.example.com:x1s8asfafasf7ssf:true,www.not-example.com:fa23rsdgsdgas:false
# ^^^ same as above, but also tells the ingress creation to use the service id fa23rsdgsdgas for ingress www.not-example.com, with the watch status of false
# Example 3: www.example.com:x1s8asfafasf7ssf:true:examplecom
# ^^^ tells the ingress creation to use the service id x1s8asfafasf7ssf for ingress www.example.com, with the watch status of true
# but it will also be annotated to be told to use the secret named `examplecom` that could be defined elsewhere
if [ ! -z "$LAGOON_PROJECT_VARIABLES" ]; then
  LAGOON_FASTLY_SERVICE_IDS=($(echo $LAGOON_PROJECT_VARIABLES | jq -r '.[] | select(.name == "LAGOON_FASTLY_SERVICE_IDS") | "\(.value)"'))
fi
if [ ! -z "$LAGOON_ENVIRONMENT_VARIABLES" ]; then
  TEMP_LAGOON_FASTLY_SERVICE_IDS=($(echo $LAGOON_ENVIRONMENT_VARIABLES | jq -r '.[] | select(.name == "LAGOON_FASTLY_SERVICE_IDS") | "\(.value)"'))
  if [ ! -z $TEMP_LAGOON_FASTLY_SERVICE_IDS ]; then
    LAGOON_FASTLY_SERVICE_IDS=$TEMP_LAGOON_FASTLY_SERVICE_IDS
  fi
fi
set -x

##############################################
### CREATE SERVICES, AUTOGENERATED ROUTES AND DBAAS CONFIG
##############################################
# start custom routes disabled
AUTOGEN_ROUTES_DISABLED=false
if [ ! -z "$LAGOON_PROJECT_VARIABLES" ]; then
  AUTOGEN_ROUTES_DISABLED=($(echo $LAGOON_PROJECT_VARIABLES | jq -r '.[] | select(.scope == "build") | select(.name == "LAGOON_AUTOGEN_ROUTES_DISABLED") | "\(.value)"'))
fi
if [ ! -z "$LAGOON_ENVIRONMENT_VARIABLES" ]; then
  TEMP_AUTOGEN_ROUTES_DISABLED=($(echo $LAGOON_ENVIRONMENT_VARIABLES | jq -r '.[] | select(.scope == "build") | select(.name == "LAGOON_AUTOGEN_ROUTES_DISABLED") | "\(.value)"'))
  if [ ! -z $TEMP_AUTOGEN_ROUTES_DISABLED ]; then
    AUTOGEN_ROUTES_DISABLED=$TEMP_AUTOGEN_ROUTES_DISABLED
  fi
fi

if [ ! "$AUTOGEN_ROUTES_DISABLED" == true ]; then
  build-deploy-tool template autogenerated-ingress
else
  echo ">> Autogenerated ingress templates disabled for this build"
# end custom route
fi

# identify any autognerated resources based on their resource name
AUTOGEN_INGRESS=$(build-deploy-tool identify created-ingress | jq -r '.autogenerated[]')
AUTOGEN_ROUTES=$(kubectl -n ${NAMESPACE} get ingress --no-headers -l "lagoon.sh/autogenerated=true" | cut -d " " -f 1 | xargs)
MATCHED_AUTOGEN=false
DELETE_AUTOGEN=()
for AR in $AUTOGEN_ROUTES; do
  for AI in $AUTOGEN_INGRESS; do
    if [ "${AR}" == "${AI}" ]; then
      MATCHED_AUTOGEN=true
      continue
    fi
  done
  if [ "${MATCHED_AUTOGEN}" != "true" ]; then
    DELETE_AUTOGEN+=($AR)
  fi
  MATCHED_AUTOGEN=false
done
for DA in ${!DELETE_AUTOGEN[@]}; do
  # delete any autogenerated ingress in the namespace as they are disabled
  if kubectl -n ${NAMESPACE} get ingress ${DELETE_AUTOGEN[$DA]} &> /dev/null; then
    echo ">> Removing autogenerated ingress for ${DELETE_AUTOGEN[$DA]} because it was disabled"
    kubectl -n ${NAMESPACE} delete ingress ${DELETE_AUTOGEN[$DA]}
  fi
done

for SERVICE_TYPES_ENTRY in "${SERVICE_TYPES[@]}"
do
  echo "=== BEGIN route processing for service ${SERVICE_TYPES_ENTRY} ==="
  IFS=':' read -ra SERVICE_TYPES_ENTRY_SPLIT <<< "$SERVICE_TYPES_ENTRY"

  TEMPLATE_PARAMETERS=()

  SERVICE_NAME=${SERVICE_TYPES_ENTRY_SPLIT[0]}
  SERVICE_TYPE=${SERVICE_TYPES_ENTRY_SPLIT[1]}

  touch /kubectl-build-deploy/${SERVICE_NAME}-values.yaml

  HELM_SERVICE_TEMPLATE="templates/service.yaml"
  if [ -f /kubectl-build-deploy/helmcharts/${SERVICE_TYPE}/$HELM_SERVICE_TEMPLATE ]; then
    SERVICE_OVERRIDES=()
    if  [[ "$SERVICE_TYPE" == "basic" ]] ||
        [[ "$SERVICE_TYPE" == "basic-persistent" ]]; then
      SERVICE_PORT_NUMBER=$(cat $DOCKER_COMPOSE_YAML | shyaml get-value services.$COMPOSE_SERVICE.labels.lagoon\\.service\\.port false)
      if [ ! $SERVICE_PORT_NUMBER == "false" ]; then
        # check if the port provided is actually a number
        if ! [[ $SERVICE_PORT_NUMBER =~ ^[0-9]+$ ]] ; then
          echo "Provided service port is not a number"; exit 1;
        fi
        SERVICE_OVERRIDES+=(--set "service.port=${SERVICE_PORT_NUMBER}")
      fi
    fi
    cat /kubectl-build-deploy/values.yaml
    helm template ${SERVICE_NAME} /kubectl-build-deploy/helmcharts/${SERVICE_TYPE} -s $HELM_SERVICE_TEMPLATE -f /kubectl-build-deploy/values.yaml "${SERVICE_OVERRIDES[@]}" "${HELM_ARGUMENTS[@]}" > $YAML_FOLDER/service-${SERVICE_NAME}.yaml
  fi

  HELM_DBAAS_TEMPLATE="templates/dbaas.yaml"
  if [ -f /kubectl-build-deploy/helmcharts/${SERVICE_TYPE}/$HELM_DBAAS_TEMPLATE ]; then
    # Load the requested class and plan for this service
    DBAAS_ENVIRONMENT="${MAP_SERVICE_NAME_TO_DBAAS_ENVIRONMENT["${SERVICE_NAME}"]}"
    yq3 write -i -- /kubectl-build-deploy/${SERVICE_NAME}-values.yaml 'environment' $DBAAS_ENVIRONMENT
    if [ ! -z "$IMAGECACHE_REGISTRY" ]; then
      yq3 write -i -- /kubectl-build-deploy/${SERVICE_NAME}-values.yaml 'imageCache' $IMAGECACHE_REGISTRY
    fi
    helm template ${SERVICE_NAME} /kubectl-build-deploy/helmcharts/${SERVICE_TYPE} -s $HELM_DBAAS_TEMPLATE -f /kubectl-build-deploy/values.yaml -f /kubectl-build-deploy/${SERVICE_NAME}-values.yaml "${HELM_ARGUMENTS[@]}" > $YAML_FOLDER/service-${SERVICE_NAME}.yaml
    DBAAS+=("${SERVICE_NAME}:${SERVICE_TYPE}")
  fi
done

set +x
currentStepEnd="$(date +"%Y-%m-%d %H:%M:%S")"
patchBuildStep "${buildStartTime}" "${previousStepEnd}" "${currentStepEnd}" "${NAMESPACE}" "serviceConfiguration2Complete" "Service Configuration Phase 2" "false"
previousStepEnd=${currentStepEnd}
beginBuildStep "Route/Ingress Configuration" "configuringRoutes"

TEMPLATE_PARAMETERS=()

##############################################
### CUSTOM ROUTES
##############################################

# Run the route generation process

# start custom routes disabled
CUSTOM_ROUTES_DISABLED=false
if [ ! -z "$LAGOON_PROJECT_VARIABLES" ]; then
  CUSTOM_ROUTES_DISABLED=($(echo $LAGOON_PROJECT_VARIABLES | jq -r '.[] | select(.scope == "build") | select(.name == "LAGOON_CUSTOM_ROUTES_DISABLED") | "\(.value)"'))
fi
if [ ! -z "$LAGOON_ENVIRONMENT_VARIABLES" ]; then
  TEMP_CUSTOM_ROUTES_DISABLED=($(echo $LAGOON_ENVIRONMENT_VARIABLES | jq -r '.[] | select(.scope == "build") | select(.name == "LAGOON_CUSTOM_ROUTES_DISABLED") | "\(.value)"'))
  if [ ! -z $TEMP_CUSTOM_ROUTES_DISABLED ]; then
    CUSTOM_ROUTES_DISABLED=$TEMP_CUSTOM_ROUTES_DISABLED
  fi
fi

if [ ! "$CUSTOM_ROUTES_DISABLED" == true ]; then
build-deploy-tool template ingress
else
  echo ">> Custom ingress templates disabled for this build"
# end custom route
fi

# apply the currently templated components out so that the route and lagoon-env configmaps gets what they need
if [ "$(ls -A $YAML_FOLDER/)" ]; then
  find $YAML_FOLDER -type f -exec cat {} \;
  kubectl apply -n ${NAMESPACE} -f $YAML_FOLDER/
fi

currentStepEnd="$(date +"%Y-%m-%d %H:%M:%S")"
patchBuildStep "${buildStartTime}" "${previousStepEnd}" "${currentStepEnd}" "${NAMESPACE}" "configuringRoutesComplete" "Route/Ingress Configuration" "false"
previousStepEnd=${currentStepEnd}
beginBuildStep "Route/Ingress Cleanup" "cleanupRoutes"

##############################################
### CLEANUP Ingress/routes which have been removed from .lagoon.yml
##############################################s

set +x
# collect the current routes excluding any certmanager requests.
# its also possible to exclude ingress by adding a label 'route.lagoon.sh/remove=false', this is then used to skip this from the removal checks
CURRENT_ROUTES=$(kubectl -n ${NAMESPACE} get ingress  -l "lagoon.sh/autogenerated!=true"  --no-headers  2> /dev/null | cut -d " " -f 1 | xargs)
# since label selectors can't be combined properly, this is done so that the build can get all the routes
# and then remove any that match our conditions to be ignored by the removal checker
IGNORE_ROUTES=$(kubectl -n ${NAMESPACE} get ingress --no-headers -l "acme.cert-manager.io/http01-solver=true"  2> /dev/null | cut -d " " -f 1 | xargs)
for SINGLE_ROUTE in ${IGNORE_ROUTES}; do
  # remove ignored routes from the current routes
  CURRENT_ROUTES=( "${CURRENT_ROUTES[@]/$SINGLE_ROUTE}" )
done
IGNORE_ROUTES=$(kubectl -n ${NAMESPACE} get ingress --no-headers -l "lagoon.sh/remove=false"  2> /dev/null | cut -d " " -f 1 | xargs)
for SINGLE_ROUTE in ${IGNORE_ROUTES}; do
  # remove ignored routes from the current routes
  CURRENT_ROUTES=( "${CURRENT_ROUTES[@]/$SINGLE_ROUTE}" )
done

# collect the routes that Lagoon thinks it should have based on the .lagoon.yml and any routes that have come from the api
# using the build-deploy-tool generator
YAML_ROUTES_TO_JSON=$(build-deploy-tool identify created-ingress | jq -r '.secondary[]')

MATCHED_INGRESS=false
DELETE_INGRESS=()
# loop over the routes from kubernetes
for SINGLE_ROUTE in ${CURRENT_ROUTES}; do
  # loop over the routes that Lagoon thinks it should have
  for YAML_ROUTE in ${YAML_ROUTES_TO_JSON}; do
    if [ "${SINGLE_ROUTE}" == "${YAML_ROUTE}" ]; then
      MATCHED_INGRESS=true
      continue
    fi
  done
  if [ "${MATCHED_INGRESS}" != "true" ]; then
    DELETE_INGRESS+=($SINGLE_ROUTE)
  fi
  MATCHED_INGRESS=false
done

CLEANUP_WARNINGS="false"
if [ ${#DELETE_INGRESS[@]} -ne 0 ]; then
  CLEANUP_WARNINGS="true"
  ((++BUILD_WARNING_COUNT))
  echo ">> Lagoon detected routes that have been removed from the .lagoon.yml or Lagoon API"
  echo "> If you need these routes, you should update your .lagoon.yml file and make sure the routes exist."
  if [ "$(featureFlag CLEANUP_REMOVED_LAGOON_ROUTES)" != enabled ]; then
    echo "> If you no longer need these routes, you can instruct Lagoon to remove it from the environment by setting the following variable"
    echo "> 'LAGOON_FEATURE_FLAG_CLEANUP_REMOVED_LAGOON_ROUTES=enabled' as a GLOBAL scoped variable to this environment or project"
    echo "> You should remove this variable after the deployment has been completed, otherwise future route removals will happen automatically"
  else
    echo "> 'LAGOON_FEATURE_FLAG_CLEANUP_REMOVED_LAGOON_ROUTES=enabled' is configured and the following routes will be removed."
    echo "> You should remove this variable if you don't want routes to be removed automatically"
  fi
  echo "> Futurue releases of Lagoon may remove routes automatically, you should ensure that your routes are up always up to date if you see this warning"
  for DI in ${DELETE_INGRESS[@]}
  do
    if [ "$(featureFlag CLEANUP_REMOVED_LAGOON_ROUTES)" = enabled ]; then
      if kubectl -n ${NAMESPACE} get ingress ${DI} &> /dev/null; then
        echo ">> Removing ingress ${DI}"
        kubectl -n ${NAMESPACE} delete ingress ${DI}
        #delete anything else?
      fi
    else
      echo "> The route '${DI}' would be removed"
    fi
  done
else
  echo "No route cleanup required"
fi

currentStepEnd="$(date +"%Y-%m-%d %H:%M:%S")"
patchBuildStep "${buildStartTime}" "${previousStepEnd}" "${currentStepEnd}" "${NAMESPACE}" "routeCleanupComplete" "Route/Ingress Cleanup" "${CLEANUP_WARNINGS}"

##############################################
### Report any ingress that have stale or stalled acme challenges, this accordion will only show if there are stale challenges
##############################################s
# collect any current challenge routes in the namespace that are older than 1 hour (to ignore current build ones or pending ones)
CURRENT_CHALLENGE_ROUTES=$(kubectl -n ${NAMESPACE} get ingress -l "acme.cert-manager.io/http01-solver=true" -o jsonpath='{range .items[*]}{.spec.rules[0].host} {.metadata.creationTimestamp}{"\n"}{end}' | while read -r name timestamp; do
        echo "$name" | awk -v current_time=$(date +%s) -v hours_back=$(date +%s -d "1 hour ago") -v ns_time=$(date --date="${timestamp}" +%s) '(current_time - ns_time) >(current_time - hours_back){print $0}';
done)
if [ "${CURRENT_CHALLENGE_ROUTES[@]}" != "" ]; then
  previousStepEnd=${currentStepEnd}
  beginBuildStep "Route/Ingress Certificate Challenges" "staleChallenges"
  ((++BUILD_WARNING_COUNT))
  echo ">> Lagoon detected routes that have stale acme certificate challenges."
  echo "  This indicates that the routes have not generated the certificate for some reason."
  echo "  You may need to verify that the DNS or configuration is correct for the hosting provider."
  echo "  https://docs.lagoon.sh/using-lagoon-the-basics/going-live/#routes-ssl"
  echo "  Depending on your going live instructions from your hosting provider, you may need to make adjustments to your .lagoon.yml file"
  echo "  Otherwise, If you no longer need these routes, you should remove them from your .lagoon.yml file."
  echo ""
  for CR in ${CURRENT_CHALLENGE_ROUTES[@]}
  do
      echo ">> The route '${CR}' has stale certificate challenge"
      # grab the error after 'order is' because the pretext could lead to confusion
      FAILURE_REASON=$(kubectl -n ${NAMESPACE} get certificate.cert-manager.io ${CR}-tls -o json | jq -r '.status.conditions[] | select (.reason=="Failed") | .message' | grep -oP "order is.*$")
      if [ -z "$FAILURE_REASON" ]; then # if there is a capturable failure reason, print it here
        echo "  reason: ${FAILURE_REASON}"
      fi
  done

  currentStepEnd="$(date +"%Y-%m-%d %H:%M:%S")"
  patchBuildStep "${buildStartTime}" "${previousStepEnd}" "${currentStepEnd}" "${NAMESPACE}" "staleChallengesComplete" "Route/Ingress Certificate Challenges" "true"
fi
previousStepEnd=${currentStepEnd}
beginBuildStep "Update Configmap" "updateConfigmap"

##############################################
### PROJECT WIDE ENV VARIABLES
##############################################

# identify primary-ingress scans the builds autogenerated and custom ingresses looking for the `main` route
# scans autogen, custom defined, and finally activestandby. first in the list is always returned for each state with each
# step overwriting the previous so only 1 ingress is returned
# previous check looked for `spec.tls` which always exists in our kubernetes templates
# so just add https...
ROUTE=$(build-deploy-tool identify primary-ingress)
if [ ! -z "${ROUTE}" ]; then
  ROUTE=${ROUTE}
fi
# if both route generations are disabled, don't set a route
if [[ "$CUSTOM_ROUTES_DISABLED" == true ]] && [[ "$AUTOGEN_ROUTES_DISABLED" == true ]]; then
  ROUTE=""
fi

# Load all routes with correct schema and comma separated
ROUTES=$(kubectl -n ${NAMESPACE} get ingress --sort-by='{.metadata.name}' -l "acme.cert-manager.io/http01-solver!=true" -o=go-template --template='{{range $indexItems, $ingress := .items}}{{if $indexItems}},{{end}}{{$tls := .spec.tls}}{{range $indexRule, $rule := .spec.rules}}{{if $indexRule}},{{end}}{{if $tls}}https://{{else}}http://{{end}}{{.host}}{{end}}{{end}}')

# swap dioscuri for activestanby label
for ingress in $(kubectl  -n ${NAMESPACE} get ingress -l "dioscuri.amazee.io/migrate" -o json | jq -r '.items[] | @base64'); do
    INGRESS_NAME=$(echo $ingress | jq -Rr '@base64d | fromjson | .metadata.name')
    MIGRATE_VALUE=$(echo $ingress | jq -Rr '@base64d | fromjson | .metadata.labels["dioscuri.amazee.io/migrate"] // false')
    PATCH='{
  "metadata": {
    "labels": {
      "activestandby.lagoon.sh/migrate": "'${MIGRATE_VALUE}'",
      "dioscuri.amazee.io/migrate": null,
      "dioscuri.amazee.io/migrated-from": null
    }
  }
}'
    kubectl -n ${NAMESPACE} patch ingress ${INGRESS_NAME} -p "${PATCH}"
done

# Active / Standby routes
ACTIVE_ROUTES=""
STANDBY_ROUTES=""
if [ ! -z "${STANDBY_ENVIRONMENT}" ]; then
ACTIVE_ROUTES=$(kubectl -n ${NAMESPACE} get ingress --sort-by='{.metadata.name}' -l "activestandby.lagoon.sh/migrate=true" -o=go-template --template='{{range $indexItems, $ingress := .items}}{{if $indexItems}},{{end}}{{$tls := .spec.tls}}{{range $indexRule, $rule := .spec.rules}}{{if $indexRule}},{{end}}{{if $tls}}https://{{else}}http://{{end}}{{.host}}{{end}}{{end}}')
STANDBY_ROUTES=$(kubectl -n ${NAMESPACE} get ingress --sort-by='{.metadata.name}' -l "activestandby.lagoon.sh/migrate=true" -o=go-template --template='{{range $indexItems, $ingress := .items}}{{if $indexItems}},{{end}}{{$tls := .spec.tls}}{{range $indexRule, $rule := .spec.rules}}{{if $indexRule}},{{end}}{{if $tls}}https://{{else}}http://{{end}}{{.host}}{{end}}{{end}}')
fi

# Get list of autogenerated routes
AUTOGENERATED_ROUTES=$(kubectl -n ${NAMESPACE} get ingress --sort-by='{.metadata.name}' -l "lagoon.sh/autogenerated=true" -o=go-template --template='{{range $indexItems, $ingress := .items}}{{if $indexItems}},{{end}}{{$tls := .spec.tls}}{{range $indexRule, $rule := .spec.rules}}{{if $indexRule}},{{end}}{{if $tls}}https://{{else}}http://{{end}}{{.host}}{{end}}{{end}}')

yq3 write -i -- /kubectl-build-deploy/values.yaml 'route' "$ROUTE"
yq3 write -i -- /kubectl-build-deploy/values.yaml 'routes' "$ROUTES"
yq3 write -i -- /kubectl-build-deploy/values.yaml 'autogeneratedRoutes' "$AUTOGENERATED_ROUTES"

echo -e "\
LAGOON_ROUTE=${ROUTE}\n\
LAGOON_ROUTES=${ROUTES}\n\
LAGOON_AUTOGENERATED_ROUTES=${AUTOGENERATED_ROUTES}\n\
" >> /kubectl-build-deploy/values.env

# Generate a Config Map with project wide env variables
kubectl -n ${NAMESPACE} create configmap lagoon-env -o yaml --dry-run=client --from-env-file=/kubectl-build-deploy/values.env | kubectl apply -n ${NAMESPACE} -f -

set +x # reduce noise in build logs
# Add environment variables from lagoon API
if [ ! -z "$LAGOON_PROJECT_VARIABLES" ]; then
  HAS_PROJECT_RUNTIME_VARS=$(echo $LAGOON_PROJECT_VARIABLES | jq -r 'map( select(.scope == "runtime" or .scope == "global") )')

  if [ ! "$HAS_PROJECT_RUNTIME_VARS" = "[]" ]; then
    kubectl patch \
      -n ${NAMESPACE} \
      configmap lagoon-env \
      -p "{\"data\":$(echo $LAGOON_PROJECT_VARIABLES | jq -r 'map( select(.scope == "runtime" or .scope == "global") ) | map( { (.name) : .value } ) | add | tostring')}"
  fi
fi
if [ ! -z "$LAGOON_ENVIRONMENT_VARIABLES" ]; then
  HAS_ENVIRONMENT_RUNTIME_VARS=$(echo $LAGOON_ENVIRONMENT_VARIABLES | jq -r 'map( select(.scope == "runtime" or .scope == "global") )')

  if [ ! "$HAS_ENVIRONMENT_RUNTIME_VARS" = "[]" ]; then
    kubectl patch \
      -n ${NAMESPACE} \
      configmap lagoon-env \
      -p "{\"data\":$(echo $LAGOON_ENVIRONMENT_VARIABLES | jq -r 'map( select(.scope == "runtime" or .scope == "global") ) | map( { (.name) : .value } ) | add | tostring')}"
  fi
fi

if [ "$BUILD_TYPE" == "pullrequest" ]; then
  kubectl patch \
    -n ${NAMESPACE} \
    configmap lagoon-env \
    -p "{\"data\":{\"LAGOON_PR_HEAD_BRANCH\":\"${PR_HEAD_BRANCH}\", \"LAGOON_PR_BASE_BRANCH\":\"${PR_BASE_BRANCH}\", \"LAGOON_PR_TITLE\":$(echo $PR_TITLE | jq -R)}}"
fi

# loop through created DBAAS
for DBAAS_ENTRY in "${DBAAS[@]}"
do
  IFS=':' read -ra DBAAS_ENTRY_SPLIT <<< "$DBAAS_ENTRY"

  SERVICE_NAME=${DBAAS_ENTRY_SPLIT[0]}
  SERVICE_TYPE=${DBAAS_ENTRY_SPLIT[1]}

  SERVICE_NAME_UPPERCASE=$(echo "$SERVICE_NAME" | tr '[:lower:]' '[:upper:]' | tr '-' '_')

  case "$SERVICE_TYPE" in

    mariadb-dbaas)
        . /kubectl-build-deploy/scripts/exec-kubectl-mariadb-dbaas.sh
        ;;

    postgres-dbaas)
        . /kubectl-build-deploy/scripts/exec-kubectl-postgres-dbaas.sh
        ;;

    mongodb-dbaas)
        . /kubectl-build-deploy/scripts/exec-kubectl-mongodb-dbaas.sh
        ;;

    *)
        echo "DBAAS Type ${SERVICE_TYPE} not implemented"; exit 1;

  esac
done

currentStepEnd="$(date +"%Y-%m-%d %H:%M:%S")"
patchBuildStep "${buildStartTime}" "${previousStepEnd}" "${currentStepEnd}" "${NAMESPACE}" "updateConfigmapComplete" "Update Configmap" "false"
previousStepEnd=${currentStepEnd}
beginBuildStep "Image Push to Registry" "pushingImages"
set -x

##############################################
### REDEPLOY DEPLOYMENTS IF CONFIG MAP CHANGES
##############################################

CONFIG_MAP_SHA=$(kubectl -n ${NAMESPACE} get configmap lagoon-env -o yaml | shyaml get-value data | sha256sum | awk '{print $1}')
# write the configmap to the values file so when we `exec-kubectl-resources-with-images.sh` the deployments will get the value of the config map
# which will cause a change in the deployment and trigger a rollout if only the configmap has changed
yq3 write -i -- /kubectl-build-deploy/values.yaml 'configMapSha' $CONFIG_MAP_SHA

##############################################
### PUSH IMAGES TO OPENSHIFT REGISTRY
##############################################

if [ "$BUILD_TYPE" == "pullrequest" ] || [ "$BUILD_TYPE" == "branch" ]; then

  # All images that should be pulled are copied to the harbor registry
  for IMAGE_NAME in "${!IMAGES_PULL[@]}"
  do
    PULL_IMAGE="${IMAGES_PULL[${IMAGE_NAME}]}"

    # Try to handle private registries first
    if [ $PRIVATE_REGISTRY_COUNTER -gt 0 ]; then
      if [ $PRIVATE_EXTERNAL_REGISTRY ]; then
        EXTERNAL_REGISTRY=0
        for EXTERNAL_REGISTRY_URL in "${PRIVATE_REGISTRY_URLS[@]}"
        do
          # strip off "http://" or "https://" from registry url if present
          bare_url="${EXTERNAL_REGISTRY_URL#http://}"
          bare_url="${EXTERNAL_REGISTRY_URL#https://}"

          # Test registry to see if image is from an external registry or just private docker hub
          case $bare_url in
            "$PULL_IMAGE"*)
              EXTERNAL_REGISTRY=1
              ;;
          esac
        done

        # If this image is hosted in an external registry, pull it from there
        if [ $EXTERNAL_REGISTRY -eq 1 ]; then
          skopeo copy --retry-times 5 --dest-tls-verify=false docker://${PULL_IMAGE} docker://${REGISTRY}/${PROJECT}/${ENVIRONMENT}/${IMAGE_NAME}:${IMAGE_TAG:-latest}
        # If this image is not from an external registry, but docker hub creds were supplied, pull it straight from Docker Hub
        elif [ $PRIVATE_DOCKER_HUB_REGISTRY -eq 1 ]; then
          skopeo copy --retry-times 5 --dest-tls-verify=false docker://${PULL_IMAGE} docker://${REGISTRY}/${PROJECT}/${ENVIRONMENT}/${IMAGE_NAME}:${IMAGE_TAG:-latest}
        # If image not from an external registry and no docker hub creds were supplied, pull image from the imagecache
        else
          skopeo copy --retry-times 5 --dest-tls-verify=false docker://${IMAGECACHE_REGISTRY}${PULL_IMAGE} docker://${REGISTRY}/${PROJECT}/${ENVIRONMENT}/${IMAGE_NAME}:${IMAGE_TAG:-latest}
        fi
      # If the private registry counter is 1 and no external registry was listed, we know a private docker hub was specified
      else
        skopeo copy --retry-times 5 --dest-tls-verify=false docker://${PULL_IMAGE} docker://${REGISTRY}/${PROJECT}/${ENVIRONMENT}/${IMAGE_NAME}:${IMAGE_TAG:-latest}
      fi
    # If no private registries, use the imagecache
    else
      skopeo copy --retry-times 5 --dest-tls-verify=false docker://${IMAGECACHE_REGISTRY}${PULL_IMAGE} docker://${REGISTRY}/${PROJECT}/${ENVIRONMENT}/${IMAGE_NAME}:${IMAGE_TAG:-latest}
    fi

    IMAGE_HASHES[${IMAGE_NAME}]=$(skopeo inspect --retry-times 5 docker://${REGISTRY}/${PROJECT}/${ENVIRONMENT}/${IMAGE_NAME}:${IMAGE_TAG:-latest} --tls-verify=false | jq ".Name + \"@\" + .Digest" -r)
  done

  for IMAGE_NAME in "${!IMAGES_BUILD[@]}"
  do
    # Before the push the temporary name is resolved to the future tag with the registry in the image name
    TEMPORARY_IMAGE_NAME="${IMAGES_BUILD[${IMAGE_NAME}]}"

    # This will actually not push any images and instead just add them to the file /kubectl-build-deploy/lagoon/push
    . /kubectl-build-deploy/scripts/exec-push-parallel.sh
  done

  # If we have Images to Push to the OpenRegistry, let's do so
  if [ -f /kubectl-build-deploy/lagoon/push ]; then
    parallel --retries 4 < /kubectl-build-deploy/lagoon/push
  fi

  # load the image hashes for just pushed Images
  for IMAGE_NAME in "${!IMAGES_BUILD[@]}"
  do
    JQ_QUERY=(jq -r ".[]|select(test(\"${REGISTRY}/${PROJECT}/${ENVIRONMENT}/${IMAGE_NAME}@\"))")
    IMAGE_HASHES[${IMAGE_NAME}]=$(docker inspect ${REGISTRY}/${PROJECT}/${ENVIRONMENT}/${IMAGE_NAME}:${IMAGE_TAG:-latest} --format '{{json .RepoDigests}}' | "${JQ_QUERY[@]}")
  done

elif [ "$BUILD_TYPE" == "promote" ]; then

  for IMAGE_NAME in "${IMAGES[@]}"
  do
    .  /kubectl-build-deploy/scripts/exec-kubernetes-promote.sh
    IMAGE_HASHES[${IMAGE_NAME}]=$(skopeo inspect --retry-times 5 docker://${REGISTRY}/${PROJECT}/${ENVIRONMENT}/${IMAGE_NAME}:${IMAGE_TAG:-latest} --tls-verify=false | jq ".Name + \"@\" + .Digest" -r)
  done

fi

set +x
currentStepEnd="$(date +"%Y-%m-%d %H:%M:%S")"
patchBuildStep "${buildStartTime}" "${previousStepEnd}" "${currentStepEnd}" "${NAMESPACE}" "imagePushComplete" "Image Push to Registry" "false"
previousStepEnd=${currentStepEnd}
beginBuildStep "Backup Configuration" "configuringBackups"
set -x

# Run the backup generation script

BACKUPS_DISABLED=false
if [ ! -z "$LAGOON_PROJECT_VARIABLES" ]; then 
  BACKUPS_DISABLED=($(echo $LAGOON_PROJECT_VARIABLES | jq -r '.[] | select(.scope == "build") | select(.name == "LAGOON_BACKUPS_DISABLED") | "\(.value)"')) 
fi 
if [ ! -z "$LAGOON_ENVIRONMENT_VARIABLES" ]; then 
  TEMP_BACKUPS_DISABLED=($(echo $LAGOON_ENVIRONMENT_VARIABLES | jq -r '.[] | select(.scope == "build") | select(.name == "LAGOON_BACKUPS_DISABLED") | "\(.value)"'))
  if [ ! -z $TEMP_BACKUPS_DISABLED ]; then
    BACKUPS_DISABLED=$TEMP_BACKUPS_DISABLED
  fi 
fi 

if [ ! "$BACKUPS_DISABLED" == true ]; then
  # check if k8up v2 feature flag is enabled
  if [ "$(featureFlag K8UP_V2)" = enabled ]; then
  # build-tool doesn't do any capability checks yet, so do this for now
    if [[ "${CAPABILITIES[@]}" =~ "k8up.io/v1/Schedule" ]]; then
    echo "Backups: generating k8up.io/v1 resources"
      if ! kubectl --insecure-skip-tls-verify -n ${NAMESPACE} get secret baas-repo-pw &> /dev/null; then
        # Create baas-repo-pw secret based on the project secret
        kubectl --insecure-skip-tls-verify -n ${NAMESPACE} create secret generic baas-repo-pw --from-literal=repo-pw=$(echo -n "${PROJECT_SECRET}-BAAS-REPO-PW" | sha256sum | cut -d " " -f 1)
      fi
      build-deploy-tool template backup-schedule --version v2
      # check if the existing schedule exists, and delete it
      if [[ "${CAPABILITIES[@]}" =~ "backup.appuio.ch/v1alpha1/Schedule" ]]; then
        if kubectl --insecure-skip-tls-verify -n ${NAMESPACE} get schedules.backup.appuio.ch k8up-lagoon-backup-schedule &> /dev/null; then
          echo "Backups: removing old backup.appuio.ch/v1alpha1 schedule"
          kubectl --insecure-skip-tls-verify -n ${NAMESPACE} delete schedules.backup.appuio.ch k8up-lagoon-backup-schedule
        fi
        if kubectl --insecure-skip-tls-verify -n ${NAMESPACE} get prebackuppods.backup.appuio.ch &> /dev/null; then
          echo "Backups: removing old backup.appuio.ch/v1alpha1 prebackuppods"
          kubectl --insecure-skip-tls-verify -n ${NAMESPACE} delete prebackuppods.backup.appuio.ch --all
        fi
      fi
      K8UP_VERSION="v2"
    fi
  fi
  if [[ "${CAPABILITIES[@]}" =~ "backup.appuio.ch/v1alpha1/Schedule" ]] && [[ "$K8UP_VERSION" != "v2" ]]; then
    echo "Backups: generating backup.appuio.ch/v1alpha1 resources"
    if ! kubectl --insecure-skip-tls-verify -n ${NAMESPACE} get secret baas-repo-pw &> /dev/null; then
      # Create baas-repo-pw secret based on the project secret
      kubectl --insecure-skip-tls-verify -n ${NAMESPACE} create secret generic baas-repo-pw --from-literal=repo-pw=$(echo -n "${PROJECT_SECRET}-BAAS-REPO-PW" | sha256sum | cut -d " " -f 1)
    fi
    build-deploy-tool template backup-schedule --version v1
  fi
else
  echo ">> Backup configurations disabled for this build"
fi

# check for ISOLATION_NETWORK_POLICY feature flag, disabled by default
if [ "$(featureFlag ISOLATION_NETWORK_POLICY)" = enabled ]; then
	# add namespace isolation network policy to deployment
	helm template isolation-network-policy /kubectl-build-deploy/helmcharts/isolation-network-policy \
		-f /kubectl-build-deploy/values.yaml \
		> $YAML_FOLDER/isolation-network-policy.yaml
fi
set -x

if [ "$(ls -A $YAML_FOLDER/)" ]; then
  find $YAML_FOLDER -type f -exec cat {} \;
  kubectl apply -n ${NAMESPACE} -f $YAML_FOLDER/
fi

set +x
currentStepEnd="$(date +"%Y-%m-%d %H:%M:%S")"
patchBuildStep "${buildStartTime}" "${previousStepEnd}" "${currentStepEnd}" "${NAMESPACE}" "backupConfigurationComplete" "Backup Configuration" "false"
previousStepEnd=${currentStepEnd}
beginBuildStep "Deployment Templating" "templatingDeployments"
set -x

##############################################
### CREATE PVC, DEPLOYMENTS AND CRONJOBS
##############################################

YAML_FOLDER="/kubectl-build-deploy/lagoon/deploymentconfigs-pvcs-cronjobs-backups"
mkdir -p $YAML_FOLDER

for SERVICE_TYPES_ENTRY in "${SERVICE_TYPES[@]}"
do
  IFS=':' read -ra SERVICE_TYPES_ENTRY_SPLIT <<< "$SERVICE_TYPES_ENTRY"

  SERVICE_NAME=${SERVICE_TYPES_ENTRY_SPLIT[0]}
  SERVICE_TYPE=${SERVICE_TYPES_ENTRY_SPLIT[1]}

  SERVICE_NAME_IMAGE="${MAP_SERVICE_NAME_TO_IMAGENAME[${SERVICE_NAME}]}"
  SERVICE_NAME_IMAGE_HASH="${IMAGE_HASHES[${SERVICE_NAME_IMAGE}]}"

  SERVICE_NAME_UPPERCASE=$(echo "$SERVICE_NAME" | tr '[:lower:]' '[:upper:]')

  COMPOSE_SERVICE=${MAP_SERVICE_TYPE_TO_COMPOSE_SERVICE["${SERVICE_TYPES_ENTRY}"]}

  # Some Templates need additonal Parameters, like where persistent storage can be found.
  HELM_SET_VALUES=()

  # PERSISTENT_STORAGE_CLASS=$(cat $DOCKER_COMPOSE_YAML | shyaml get-value services.$COMPOSE_SERVICE.labels.lagoon\\.persistent\\.class false)
  # if [ ! $PERSISTENT_STORAGE_CLASS == "false" ]; then
  #     TEMPLATE_PARAMETERS+=(-p PERSISTENT_STORAGE_CLASS="${PERSISTENT_STORAGE_CLASS}")
  # fi

  PERSISTENT_STORAGE_SIZE=$(cat $DOCKER_COMPOSE_YAML | shyaml get-value services.$COMPOSE_SERVICE.labels.lagoon\\.persistent\\.size false)
  if [ ! $PERSISTENT_STORAGE_SIZE == "false" ]; then
    HELM_SET_VALUES+=(--set "persistentStorage.size=${PERSISTENT_STORAGE_SIZE}")
  fi

  PERSISTENT_STORAGE_PATH=$(cat $DOCKER_COMPOSE_YAML | shyaml get-value services.$COMPOSE_SERVICE.labels.lagoon\\.persistent false)
  if [ ! $PERSISTENT_STORAGE_PATH == "false" ]; then
    HELM_SET_VALUES+=(--set "persistentStorage.path=${PERSISTENT_STORAGE_PATH}")

    PERSISTENT_STORAGE_NAME=$(cat $DOCKER_COMPOSE_YAML | shyaml get-value services.$COMPOSE_SERVICE.labels.lagoon\\.persistent\\.name false)
    if [ ! $PERSISTENT_STORAGE_NAME == "false" ]; then
      HELM_SET_VALUES+=(--set "persistentStorage.name=${PERSISTENT_STORAGE_NAME}")
    else
      HELM_SET_VALUES+=(--set "persistentStorage.name=${SERVICE_NAME}")
    fi
  fi

  # all our templates appear to support this if they have a service defined in them, but only `basic` properly supports this
  # as all services will get re-written in the future into build-deploy-tool, just handle basic only for now and don't
  # support it in other templates (yet)
  if  [[ "$SERVICE_TYPE" == "basic" ]] ||
      [[ "$SERVICE_TYPE" == "basic-persistent" ]]; then
    SERVICE_PORT_NUMBER=$(cat $DOCKER_COMPOSE_YAML | shyaml get-value services.$COMPOSE_SERVICE.labels.lagoon\\.service\\.port false)
    if [ ! $SERVICE_PORT_NUMBER == "false" ]; then
      # check if the port provided is actually a number
      if ! [[ $SERVICE_PORT_NUMBER =~ ^[0-9]+$ ]] ; then
        echo "Provided service port is not a number"; exit 1;
      fi
      HELM_SET_VALUES+=(--set "service.port=${SERVICE_PORT_NUMBER}")
    fi
  fi

  # handle spot configurations
  . /kubectl-build-deploy/scripts/exec-spot-generation.sh

  # handle dynamically added secrets
  . /kubectl-build-deploy/scripts/exec-dynamic-secret-volumes.sh

# TODO: we don't need this anymore
  # DEPLOYMENT_STRATEGY=$(cat $DOCKER_COMPOSE_YAML | shyaml get-value services.$COMPOSE_SERVICE.labels.lagoon\\.deployment\\.strategy false)
  # if [ ! $DEPLOYMENT_STRATEGY == "false" ]; then
  #   TEMPLATE_PARAMETERS+=(-p DEPLOYMENT_STRATEGY="${DEPLOYMENT_STRATEGY}")
  # fi

  # start cronjob disabled
  CRONJOBS_DISABLED=false
  if [ ! -z "$LAGOON_PROJECT_VARIABLES" ]; then
    CRONJOBS_DISABLED=($(echo $LAGOON_PROJECT_VARIABLES | jq -r '.[] | select(.scope == "build") | select(.name == "LAGOON_CRONJOBS_DISABLED") | "\(.value)"'))
  fi
  if [ ! -z "$LAGOON_ENVIRONMENT_VARIABLES" ]; then
    TEMP_CRONJOBS_DISABLED=($(echo $LAGOON_ENVIRONMENT_VARIABLES | jq -r '.[] | select(.scope == "build") | select(.name == "LAGOON_CRONJOBS_DISABLED") | "\(.value)"'))
    if [ ! -z $TEMP_CRONJOBS_DISABLED ]; then
      CRONJOBS_DISABLED=$TEMP_CRONJOBS_DISABLED
    fi
  fi

  if [ ! "$CRONJOBS_DISABLED" == true ]; then
  CRONJOB_COUNTER=0
  CRONJOBS_ARRAY_INSIDE_POD=()   #crons run inside an existing pod more frequently than every 15 minutes
  while [ -n "$(cat .lagoon.yml | shyaml keys environments.${BRANCH//./\\.}.cronjobs.$CRONJOB_COUNTER 2> /dev/null)" ]
  do

    CRONJOB_SERVICE=$(cat .lagoon.yml | shyaml get-value environments.${BRANCH//./\\.}.cronjobs.$CRONJOB_COUNTER.service)

    # Only implement the cronjob for the services we are currently handling
    if [ $CRONJOB_SERVICE == $SERVICE_NAME ]; then

      CRONJOB_NAME=$(cat .lagoon.yml | shyaml get-value environments.${BRANCH//./\\.}.cronjobs.$CRONJOB_COUNTER.name | sed "s/[^[:alnum:]-]/-/g" | sed "s/^-//g")

      CRONJOB_SCHEDULE_RAW=$(cat .lagoon.yml | shyaml get-value environments.${BRANCH//./\\.}.cronjobs.$CRONJOB_COUNTER.schedule)

      # Convert the Cronjob Schedule for additional features and better spread
      CRONJOB_SCHEDULE=$( /kubectl-build-deploy/scripts/convert-crontab.sh "${NAMESPACE}" "$CRONJOB_SCHEDULE_RAW")
      CRONJOB_COMMAND=$(cat .lagoon.yml | shyaml get-value environments.${BRANCH//./\\.}.cronjobs.$CRONJOB_COUNTER.command)

      if cronScheduleMoreOftenThan30Minutes "$CRONJOB_SCHEDULE_RAW" ; then
        # If this cronjob is more often than 30 minutes, we run the cronjob inside the pod itself
        CRONJOBS_ARRAY_INSIDE_POD+=("${CRONJOB_SCHEDULE} ${CRONJOB_COMMAND}")
      else
        # This cronjob runs less ofen than every 30 minutes, we create a kubernetes native cronjob for it.

        # Add this cronjob to the native cleanup array, this will remove native cronjobs at the end of this script
        NATIVE_CRONJOB_CLEANUP_ARRAY+=($(echo "cronjob-${SERVICE_NAME}-${CRONJOB_NAME}" | awk '{print tolower($0)}'))
        # kubectl stores this cronjob name lowercased

        # if [ ! -f $OPENSHIFT_TEMPLATE ]; then
        #   echo "No cronjob support for service '${SERVICE_NAME}' with type '${SERVICE_TYPE}', please contact the Lagoon maintainers to implement cronjob support"; exit 1;
        # else

        yq3 write -i -- /kubectl-build-deploy/${SERVICE_NAME}-values.yaml "nativeCronjobs.${CRONJOB_NAME,,}.schedule" "$CRONJOB_SCHEDULE"
        yq3 write -i -- /kubectl-build-deploy/${SERVICE_NAME}-values.yaml "nativeCronjobs.${CRONJOB_NAME,,}.command" "$CRONJOB_COMMAND"

        # fi
      fi
    fi

    let CRONJOB_COUNTER=CRONJOB_COUNTER+1
  done


  # if there are cronjobs running inside pods, add them to the deploymentconfig.
  if [[ ${#CRONJOBS_ARRAY_INSIDE_POD[@]} -ge 1 ]]; then
    yq3 write -i -- /kubectl-build-deploy/${SERVICE_NAME}-values.yaml 'inPodCronjobs' "$(printf '%s\n' "${CRONJOBS_ARRAY_INSIDE_POD[@]}")"
  else
    yq3 write -i --tag '!!str' -- /kubectl-build-deploy/${SERVICE_NAME}-values.yaml 'inPodCronjobs' ''
  fi

  else
    echo ">> Cronjob configurations disabled for this build"
  fi
  # end cronjob disabled

  . /kubectl-build-deploy/scripts/exec-kubectl-resources-with-images.sh

done

set +x
currentStepEnd="$(date +"%Y-%m-%d %H:%M:%S")"
patchBuildStep "${buildStartTime}" "${previousStepEnd}" "${currentStepEnd}" "${NAMESPACE}" "deploymentTemplatingComplete" "Deployment Templating" "false"
previousStepEnd=${currentStepEnd}
beginBuildStep "Applying Deployments" "applyingDeployments"
set -x

##############################################
### APPLY RESOURCES
##############################################

# remove any storage calculator pods before applying deployments to prevent storage binding issues
STORAGE_CALCULATOR_PODS=$(kubectl -n ${NAMESPACE} get pods -l lagoon.sh/storageCalculator=true --no-headers | cut -d " " -f 1 | xargs)
for STORAGE_CALCULATOR_POD in $STORAGE_CALCULATOR_PODS; do
  kubectl -n ${NAMESPACE} delete pod ${STORAGE_CALCULATOR_POD}
done

set +x
if [ "$(ls -A $YAML_FOLDER/)" ]; then
  if [ "$CI" == "true" ]; then
    # During CI tests of Lagoon itself we only have a single compute node, so we change podAntiAffinity to podAffinity
    find $YAML_FOLDER -type f  -print0 | xargs -0 sed -i s/podAntiAffinity/podAffinity/g
    # During CI tests of Lagoon itself we only have a single compute node, so we change ReadWriteMany to ReadWriteOnce
    find $YAML_FOLDER -type f  -print0 | xargs -0 sed -i s/ReadWriteMany/ReadWriteOnce/g
  fi
  if [ "$(featureFlag RWX_TO_RWO)" = enabled ]; then
    # If there is only a single compute node, this can be used to change RWX to RWO
    find $YAML_FOLDER -type f  -print0 | xargs -0 sed -i s/ReadWriteMany/ReadWriteOnce/g
  fi

  find $YAML_FOLDER -type f -exec cat {} \;
  kubectl apply -n ${NAMESPACE} -f $YAML_FOLDER/
fi
set -x

##############################################
### WAIT FOR POST-ROLLOUT TO BE FINISHED
##############################################

for SERVICE_TYPES_ENTRY in "${SERVICE_TYPES[@]}"
do

  IFS=':' read -ra SERVICE_TYPES_ENTRY_SPLIT <<< "$SERVICE_TYPES_ENTRY"

  SERVICE_NAME=${SERVICE_TYPES_ENTRY_SPLIT[0]}
  SERVICE_TYPE=${SERVICE_TYPES_ENTRY_SPLIT[1]}

  SERVICE_ROLLOUT_TYPE=$(cat $DOCKER_COMPOSE_YAML | shyaml get-value services.${SERVICE_NAME}.labels.lagoon\\.rollout deployment)

  # Allow the rollout type to be overriden by environment in .lagoon.yml
  ENVIRONMENT_SERVICE_ROLLOUT_TYPE=$(cat .lagoon.yml | shyaml get-value environments.${BRANCH//./\\.}.rollouts.${SERVICE_NAME} false)
  if [ ! $ENVIRONMENT_SERVICE_ROLLOUT_TYPE == "false" ]; then
    SERVICE_ROLLOUT_TYPE=$ENVIRONMENT_SERVICE_ROLLOUT_TYPE
  fi

  if [ $SERVICE_TYPE == "mariadb-dbaas" ]; then

    echo "nothing to monitor for $SERVICE_TYPE"

  elif [ $SERVICE_TYPE == "postgres-dbaas" ]; then

    echo "nothing to monitor for $SERVICE_TYPE"

  elif [ $SERVICE_TYPE == "mongodb-dbaas" ]; then

    echo "nothing to monitor for $SERVICE_TYPE"

  elif [ ! $SERVICE_ROLLOUT_TYPE == "false" ]; then
    . /kubectl-build-deploy/scripts/exec-monitor-deploy.sh
  fi
done

set +x
currentStepEnd="$(date +"%Y-%m-%d %H:%M:%S")"
patchBuildStep "${buildStartTime}" "${previousStepEnd}" "${currentStepEnd}" "${NAMESPACE}" "deploymentApplyComplete" "Applying Deployments" "false"
previousStepEnd=${currentStepEnd}
beginBuildStep "Cronjob Cleanup" "cleaningUpCronjobs"
set -x

##############################################
### CLEANUP NATIVE CRONJOBS which have been removed from .lagoon.yml or modified to run more frequently than every 15 minutes
##############################################

CURRENT_CRONJOBS=$(kubectl -n ${NAMESPACE} get cronjobs --no-headers | cut -d " " -f 1 | xargs)
MATCHED_CRONJOB=false
DELETE_CRONJOBS=()
# NATIVE_CRONJOB_CLEANUP_ARRAY is calculated in a prior step, when cronjobs are generated by the build-deploy-tool, this will need to be re-calculated using the tool
for SINGLE_NATIVE_CRONJOB in $CURRENT_CRONJOBS; do
  for CLEANUP_NATIVE_CRONJOB in ${NATIVE_CRONJOB_CLEANUP_ARRAY[@]}; do
    if [ "${SINGLE_NATIVE_CRONJOB}" == "${CLEANUP_NATIVE_CRONJOB}" ]; then
      MATCHED_CRONJOB=true
      continue
    fi
  done
  if [ "${MATCHED_CRONJOB}" != "true" ]; then
    DELETE_CRONJOBS+=($SINGLE_NATIVE_CRONJOB)
  fi
  MATCHED_CRONJOB=false
done
for DC in ${!DELETE_CRONJOBS[@]}; do
  # delete any cronjobs if they were removed
  if kubectl -n ${NAMESPACE} get cronjob ${DELETE_CRONJOBS[$DC]} &> /dev/null; then
    echo ">> Removing cronjob ${DELETE_CRONJOBS[$DC]} because it was removed"
    kubectl -n ${NAMESPACE} delete cronjob ${DELETE_CRONJOBS[$DC]}
  fi
done

set +x
currentStepEnd="$(date +"%Y-%m-%d %H:%M:%S")"
patchBuildStep "${buildStartTime}" "${previousStepEnd}" "${currentStepEnd}" "${NAMESPACE}" "cronjobCleanupComplete" "Cronjob Cleanup" "false"
previousStepEnd=${currentStepEnd}
beginBuildStep "Post-Rollout Tasks" "runningPostRolloutTasks"
set -x

##############################################
### RUN POST-ROLLOUT tasks defined in .lagoon.yml
##############################################

# if we have LAGOON_POSTROLLOUT_DISABLED set, don't try to run any pre-rollout tasks
if [ "${LAGOON_POSTROLLOUT_DISABLED}" != "true" ]; then
  build-deploy-tool tasks post-rollout
else
  echo "post-rollout tasks are currently disabled LAGOON_POSTROLLOUT_DISABLED is set to true"
  set +x
  currentStepEnd="$(date +"%Y-%m-%d %H:%M:%S")"
  patchBuildStep "${buildStartTime}" "${previousStepEnd}" "${currentStepEnd}" "${NAMESPACE}" "postRolloutsCompleted" "Post-Rollout Tasks" "false"
  set -x
fi

set +x
currentStepEnd="$(date +"%Y-%m-%d %H:%M:%S")"
previousStepEnd=${currentStepEnd}
beginBuildStep "Build and Deploy" "finalizingBuild"
set -x

##############################################
### PUSH the latest .lagoon.yml into lagoon-yaml configmap
##############################################

set +x
echo "Updating lagoon-yaml configmap with a post-deploy version of the .lagoon.yml file"
if kubectl -n ${NAMESPACE} get configmap lagoon-yaml &> /dev/null; then
  # replace it, no need to check if the key is different, as that will happen in the pre-deploy phase
  kubectl -n ${NAMESPACE} get configmap lagoon-yaml -o json | jq --arg add "`cat .lagoon.yml`" '.data."post-deploy" = $add' | kubectl apply -f -
 else
  # create it
  kubectl -n ${NAMESPACE} create configmap lagoon-yaml --from-file=post-deploy=.lagoon.yml
fi
echo "Updating docker-compose-yaml configmap with a post-deploy version of the docker-compose.yml file"
if kubectl -n ${NAMESPACE} get configmap docker-compose-yaml &> /dev/null; then
  # replace it, no need to check if the key is different, as that will happen in the pre-deploy phase
  kubectl -n ${NAMESPACE} get configmap docker-compose-yaml -o json | jq --arg add "`cat ${DOCKER_COMPOSE_YAML}`" '.data."post-deploy" = $add' | kubectl apply -f -
 else
  # create it
  kubectl -n ${NAMESPACE} create configmap docker-compose-yaml --from-file=post-deploy=${DOCKER_COMPOSE_YAML}
fi

# remove any certificates for tls-acme false ingress to prevent reissuing attempts
TLS_FALSE_INGRESSES=$(kubectl -n ${NAMESPACE} get ingress -o json | jq -r '.items[] | select(.metadata.annotations["kubernetes.io/tls-acme"] == "false") | .metadata.name')
for TLS_FALSE_INGRESS in $TLS_FALSE_INGRESSES; do
  TLS_SECRETS=$(kubectl -n ${NAMESPACE} get ingress ${TLS_FALSE_INGRESS} -o json | jq -r '.spec.tls[]?.secretName')
  for TLS_SECRET in $TLS_SECRETS; do
    echo ">> Cleaning up certificate for ${TLS_SECRET} as tls-acme is set to false"
    # check if it is a lets encrypt certificate
    if openssl x509 -in <(kubectl -n ${NAMESPACE} get secret ${TLS_SECRET}-tls -o json | jq -r '.data."tls.crt"' | base64 --decode) -text -noout | grep -o -q "Let's Encrypt" s &> /dev/null; then
      kubectl -n ${NAMESPACE} delete secret ${TLS_SECRET}-tls
    fi
    if kubectl -n ${NAMESPACE} get certificates.cert-manager.io ${TLS_SECRET} &> /dev/null; then
      kubectl -n ${NAMESPACE} delete certificates.cert-manager.io ${TLS_SECRET}
    fi
  done
done
set -x

set +x
currentStepEnd="$(date +"%Y-%m-%d %H:%M:%S")"
patchBuildStep "${buildStartTime}" "${previousStepEnd}" "${currentStepEnd}" "${NAMESPACE}" "deployCompleted" "Build and Deploy" "false"
previousStepEnd=${currentStepEnd}

if [ "$(featureFlag INSIGHTS)" = enabled ]; then
  beginBuildStep "Insights Gathering" "gatheringInsights"
  ##############################################
  ### RUN insights gathering and store in configmap
  ##############################################

  for IMAGE_NAME in "${!IMAGES_BUILD[@]}"
  do

    IMAGE_TAG="${IMAGE_TAG:-latest}"
    IMAGE_FULL="${REGISTRY}/${PROJECT}/${ENVIRONMENT}/${IMAGE_NAME}:${IMAGE_TAG}"
    . /kubectl-build-deploy/scripts/exec-generate-insights-configmap.sh
  done

  currentStepEnd="$(date +"%Y-%m-%d %H:%M:%S")"
  patchBuildStep "${buildStartTime}" "${previousStepEnd}" "${currentStepEnd}" "${NAMESPACE}" "insightsCompleted" "Insights Gathering" "false"
  previousStepEnd=${currentStepEnd}

  if [[ "$BUILD_WARNING_COUNT" -gt 0 ]]; then
    beginBuildStep "Completed With Warnings" "deployCompletedWithWarnings"
    echo "This build completed with ${BUILD_WARNING_COUNT} warnings, you should scan the build for warnings and correct them as neccessary"
    patchBuildStep "${buildStartTime}" "${previousStepEnd}" "${currentStepEnd}" "${NAMESPACE}" "deployCompletedWithWarnings" "Completed With Warnings" "true"
    previousStepEnd=${currentStepEnd}
    # patch the buildpod with the buildstep
    if [ "${SCC_CHECK}" == false ]; then
      kubectl patch -n ${NAMESPACE} pod ${LAGOON_BUILD_NAME} \
        -p "{\"metadata\":{\"labels\":{\"lagoon.sh/buildStep\":\"deployCompletedWithWarnings\"}}}" &> /dev/null
      # tiny sleep to allow patch to complete before logs roll again
      sleep 5
    fi
  fi
else
  if [[ "$BUILD_WARNING_COUNT" -gt 0 ]]; then
    beginBuildStep "Completed With Warnings" "deployCompletedWithWarnings"
    echo "This build completed with ${BUILD_WARNING_COUNT} warnings, you should scan the build for warnings and correct them as neccessary"
    patchBuildStep "${buildStartTime}" "${previousStepEnd}" "${currentStepEnd}" "${NAMESPACE}" "deployCompletedWithWarnings" "Completed With Warnings" "true"
    previousStepEnd=${currentStepEnd}
    # patch the buildpod with the buildstep
    if [ "${SCC_CHECK}" == false ]; then
      kubectl patch -n ${NAMESPACE} pod ${LAGOON_BUILD_NAME} \
        -p "{\"metadata\":{\"labels\":{\"lagoon.sh/buildStep\":\"deployCompletedWithWarnings\"}}}" &> /dev/null
      # tiny sleep to allow patch to complete before logs roll again
      sleep 5
    fi
  fi
fi
set -x
