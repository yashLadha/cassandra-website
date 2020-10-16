#!/bin/bash

# Abort script if a command fails
set -e

export CASSANDRA_USE_JDK11=true
export CASSANDRA_WEBSITE_DIR="${BUILD_DIR}/cassandra-website"
export CASSANDRA_DIR="${BUILD_DIR}/cassandra"
export CASSANDRA_DOC="${CASSANDRA_DIR}/doc"
GIT_USER_SETUP="false"

setup_git_user() {
  if [ "${GIT_USER_SETUP}" = "false" ]
  then
    # Setup git so we can commit back to the Cassandra repository locally
    git config --global user.email "${GIT_EMAIL_ADDRESS}"
    git config --global user.name "${GIT_USER_NAME}"
    GIT_USER_SETUP="true"
  fi
}

generate_cassandra_versioned_docs() {
  if [ "$(find "${CASSANDRA_DIR}" -mindepth 1 -type f | wc -l)" -eq 0 ]
  then
    git clone "${ANTORA_CONTENT_SOURCES_CASSANDRA_URL}" "${BUILD_DIR}"/cassandra

    # Once the repository has been cloned set the Antora Cassandra source URL to be the local copy we have cloned in
    # the container. This is so it will be used as the version documentation source by Antora if we are generating the
    # website HTML.
    ANTORA_CONTENT_SOURCES_CASSANDRA_URL="${BUILD_DIR}"/cassandra
  fi

  # If we are generating the website HTML as well, make sure the versioned documentation is part of the output.
  INCLUDE_VERSION_DOCS_WHEN_GENERATING_WEBSITE="enabled"

  mkdir -p "${CASSANDRA_DIR}"/cassandra/doc/build_gen

  local commit_changes_to_branch=""
  if [ "$(wc -w <<< "${GENERATE_CASSANDRA_VERSIONS}")" -gt 1 ] || [ "${COMMIT_GENERATED_VERSION_DOCS_TO_REPOSITORY}" = "enabled" ]
  then
    commit_changes_to_branch="enabled"
  else
    commit_changes_to_branch="disabled"
  fi

  for version in ${GENERATE_CASSANDRA_VERSIONS}
  do
    echo "Checking out '${version}'"
    pushd "${CASSANDRA_DIR}" > /dev/null
    git clean -xdff
    git checkout "${version}"
    git pull --rebase --prune

    echo "Building JAR files"
    # Nodetool docs are autogenerated, but that needs nodetool to be built
    ant jar
    local doc_version=""
    doc_version=$(ant echo-base-version | grep "\[echo\]" | tr -s ' ' | cut -d' ' -f3)
    popd > /dev/null

    pushd "${CASSANDRA_DOC}" > /dev/null
    # cassandra-3.11 is missing gen-nodetool-docs.py, ref: CASSANDRA-16093
    gen_nodetool_docs=$(find . -iname gen-nodetool-docs.py | head -n 1)
    if [ ! -f "${gen_nodetool_docs}" ]
    then
      echo "Unable to find ${gen_nodetool_docs}, so I will download it from the Cassandra repository using commit a47be7e."
      wget \
        -nc \
        -O ./gen-nodetool-docs.py \
        https://raw.githubusercontent.com/apache/cassandra/a47be7eddd5855fc7723d4080ca1a63c611efdab/doc/gen-nodetool-docs.py
    fi

    echo "Generating asciidoc for version ${doc_version}"
    # generate the nodetool docs
    python3 "${gen_nodetool_docs}"

    # generate cassandra.yaml docs
    local convert_yaml_to_adoc=$(find . -iname convert_yaml_to_adoc.py | head -n 1)
    if [ -f "${gen_nodetool_docs}" ]
    then
      YAML_INPUT="${CASSANDRA_DIR}/conf/cassandra.yaml"
      YAML_OUTPUT="${CASSANDRA_DOC}/modules/cassandra/pages/configuration/cass_yaml_file.adoc"
      python3 "${convert_yaml_to_adoc}" "${YAML_INPUT}" "${YAML_OUTPUT}"
    fi

    if [ "${commit_changes_to_branch}" = "enabled" ]
    then
      git add .
      git commit -m "Generated nodetool and configuration documentation for ${doc_version}." || echo "No new changes to commit."
    fi
    popd > /dev/null
  done
}

string_to_json() {
  local key="${1}"
  local value="${2}"

  echo -e "\"${key}\":\"${value}\""
}

list_to_json() {
  local key="${1}"
  local value="${2}"

  echo -e "\"${key}\":[$(echo \""${value}"\" | sed 's~\ ~\",\"~g')]"
}

generate_json() {
  local json_output
  local count

  json_output="{"
  count=1
  while true
  do
    local arg
    local json_type
    local key
    local value

    arg="${!count}"

    if [ -z "${arg}" ]
    then
      break
    fi

    json_type="$(cut -d':' -f1 <<< ${arg})"
    key="$(cut -d':' -f2 <<< ${arg})"
    value=${arg//${json_type}:${key}:/}
    if [ -n "${value}" ]
    then
      json_obj=$("${json_type}_to_json" "${key}" "${value}")

      if [ "${json_output}" = "{" ]
      then
        json_output="${json_output}${json_obj}"
      else
        json_output="${json_output},${json_obj}"
      fi
    fi
    count=$((count + 1))
  done
  json_output="${json_output}}"

  echo -e "${json_output}"
}

generate_site_yaml() {
  pushd "${CASSANDRA_WEBSITE_DIR}/site-content" > /dev/null

  if [ "${INCLUDE_VERSION_DOCS_WHEN_GENERATING_WEBSITE}" = "enabled" ]
  then
    ANTORA_CONTENT_SOURCE_REPOSITORIES+=(CASSANDRA)
  fi

  local repository_url=""
  local start_path=""
  local branches=""
  local tags=""
  local content_source_options=()
  for repo in ${ANTORA_CONTENT_SOURCE_REPOSITORIES[*]}
  do
    repository_url=$(eval echo "$"ANTORA_CONTENT_SOURCES_${repo}_URL"")
    start_path=$(eval echo "$"ANTORA_CONTENT_SOURCES_${repo}_START_PATH"")
    branches=$(eval echo "$"ANTORA_CONTENT_SOURCES_${repo}_BRANCHES"")
    tags=$(eval echo "$"ANTORA_CONTENT_SOURCES_${repo}_TAGS"")

    if [ -n "${repository_url}" ] && [ -n "${start_path}" ] && { [ -n "${branches}" ] || [ -n "${tags}" ]; }
    then
      content_source_options+=("-c")
      content_source_options+=("$(generate_json \
          "string:url:${repository_url}" \
          "string:start_path:${start_path}" \
          "list:branches:${branches}" \
          "list:tags:${tags}")")
    fi
  done

  echo "Building site.yaml"
  rm -f site.yaml
  python3 ./bin/site_yaml_generator.py \
    -s "$(generate_json \
          "string:title:${ANTORA_SITE_TITLE}" \
          "string:url:${ANTORA_SITE_URL}" \
          "string:start_page:${ANTORA_SITE_START_PAGE}") "\
    "${content_source_options[@]}" \
    -u "${ANTORA_UI_BUNDLE_URL}" \
    -r "${CASSANDRA_DOWNLOADS_URL}" \
    site.template.yaml
  popd > /dev/null
}

render_site_content_to_html() {
  pushd "${CASSANDRA_WEBSITE_DIR}/site-content" > /dev/null
  echo "Building the site HTML content."
  antora --generator antora-site-generator-lunr site.yaml
  echo "Rendering complete!"
  popd > /dev/null
}

run_preview_mode() {
  echo "Entering preview mode!"

  export -f render_site_content_to_html

  local on_change_functions="render_site_content_to_html"
  local find_paths="${CASSANDRA_WEBSITE_DIR}/${ANTORA_CONTENT_SOURCES_CASSANDRA_WEBSITE_START_PATH}"

  if [ "${COMMAND_GENERATE_DOCS}" = "run" ]
  then
    on_change_functions="generate_cassandra_versioned_docs && ${on_change_functions}"
    find_paths="${find_paths} ${CASSANDRA_DIR}/${ANTORA_CONTENT_SOURCES_CASSANDRA_START_PATH}"

    export -f generate_cassandra_versioned_docs

    # Ensure we only have one branch to generate docs for
    GENERATE_CASSANDRA_VERSIONS=$(cut -d' ' -f1 <<< "${GENERATE_CASSANDRA_VERSIONS}")
  fi

  if [ "${COMMAND_BUILD_SITE}" != "run" ]
  then
    generate_site_yaml

    export DOCSEARCH_ENABLED=true
    export DOCSEARCH_ENGINE=lunr
    export NODE_PATH="$(npm -g root)"
    export DOCSEARCH_INDEX_VERSION=latest

    render_site_content_to_html
  fi

  pushd "${CASSANDRA_WEBSITE_DIR}/site-content/build/html" > /dev/null
  live-server --port=5151 --host=0.0.0.0 --no-browser --no-css-inject --wait=2000 &
  popd > /dev/null

  find "${find_paths}" -type f | entr /bin/bash -c "${on_change_functions}"
}


# ============ MAIN ============

GENERATE_CASSANDRA_VERSIONS=$(sed 's/^[[:space:]]]*//' <<< "${ANTORA_CONTENT_SOURCES_CASSANDRA_BRANCHES} ${ANTORA_CONTENT_SOURCES_CASSANDRA_TAGS}")
export GENERATE_CASSANDRA_VERSIONS

ANTORA_CONTENT_SOURCE_REPOSITORIES=(
  CASSANDRA_WEBSITE
)

# Initialise commands and assume none of them will run
COMMAND_GENERATE_DOCS="skip"
COMMAND_BUILD_SITE="skip"
COMMAND_PREVIEW="skip"

# Work out which commands the caller has requested. We need to do this first as the commands should be run in a certain order
while [ "$1" != "" ]
do
  case $1 in
    "generate-docs")
      COMMAND_GENERATE_DOCS="run"
    ;;
    "build-site")
      COMMAND_BUILD_SITE="run"
    ;;
    "preview")
      COMMAND_PREVIEW="run"
    ;;
    *)
      echo "Skipping unrecognised command '$1'."
    ;;
  esac

  shift
done

# Execute the commands as requested by the caller.
if [ "${COMMAND_GENERATE_DOCS}" = "run" ]
then
  setup_git_user
  generate_cassandra_versioned_docs
fi

if [ "${COMMAND_BUILD_SITE}" = "run" ]
then
  generate_site_yaml

  export DOCSEARCH_ENABLED=true
  export DOCSEARCH_ENGINE=lunr
  export NODE_PATH="$(npm -g root)"
  export DOCSEARCH_INDEX_VERSION=latest

  render_site_content_to_html
fi

if [ "${COMMAND_PREVIEW}" = "run" ]
then
  run_preview_mode
fi