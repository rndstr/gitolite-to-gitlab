#!/bin/sh
#
# A script to migrate gitolite repositories to gitlab.
#
# Downloads the repository list from the `gitolite-admin` repository and mirrors all repositories to a gitlab host
# under a given user as a private repo.
#
# https://github.com/rndstr/gitolite-to-gitlab

usage () {
    exec 4<&1
    exec 1>&2
    echo "usage: $(basename $0) [-i] <gitolite-admin-uri> <gitlab-url> <gitlab-user> <gitlab-token>"
    echo
    echo "  -i  Confirm each repository to migrate"
    echo "  -h  Display this help"
    echo
    echo "  gitolite-admin-uri  Repository URI for the gitolite-admin repo (e.g., gitolite@example.com:gitolite-admin.git)"
    echo "  gitlab-url          Where your GitLab is hosted (e.g., https://www.gitlab.com)"
    echo "  gitlab-user         Username for which the projects should be created"
    echo "  gitlab-token        Private token for the API to create the projects (see https://www.gitlab.com/profile/account)"
    exec 1<&4
}

log () {
    echo -e "\e[0;33m>>> $*\e[0m"
}

success () {
    echo -e "\e[0;32m>>> $*\e[0m"
}

error () {
    echo -e "\e[0;31mERROR: $*\e[0m" 1>&2
}

clone_repo () {
    lite_repo=$1; lab_repo=$2

    target=$cwd/tmp/$lab_repo
    repo_uri=${gitolite_base_uri}:${lite_repo}.git

    if [ -d $target ]; then
        log "$lite_repo: found"
    else
        log "$lite_repo@gitolite: download from $repo_uri"
        set +e
        git clone --mirror $repo_uri $target
        if [ $? -eq 1 ]; then
            # cleanup
            rm -r $target
            exit 1
        fi
        set -e
    fi
}

create_repo () {
    lite_repo=$1; lab_repo=$2

    log "$lite_repo@gitlab: create project $gitlab_url/$gitlab_user/$lab_repo"

    set +e
    body=$(curl --silent --header "PRIVATE-TOKEN: $gitlab_token" "$gitlab_url/api/v3/projects" --data "name=$lab_repo&path=$lab_repo")
    if [[ $body == *"has already been taken"* ]]; then
        log "$lite_repo@gitlab: already exists"
    fi
    set -e
}

push_repo () {
    lite_repo=$1; lab_repo=$2

    lab_uri=git@$gitlab_domain:${gitlab_user}/${lab_repo}.git
    log "$lite_repo@gitlab: upload to $lab_uri"

    cd $cwd/tmp/$lab_repo
    git push --mirror $lab_uri
    success "$lite_repo: migrated"
}

clean_repo () {
    lab_repo=$1
    test -z $lab_repo && { error "this doesn't seem right, repo is empty; bailing"; exit 1; }
    cd $cwd
    rm -rf $cwd/tmp/$lab_repo
    touch $cwd/tmp/${lab_repo}-migrated
}


interactive=0
while getopts hi name; do
    case $name in
        i) interactive=1;;
        h) usage; exit 1;;
        \?) usage; exit 2;;
    esac
done
shift $((OPTIND-1))

if [ $# -ne 4 ]; then
    error "missing arguments"
    usage
    exit 2
fi


gitolite_admin_uri=$1
gitlab_url=$2
gitlab_user=$3
gitlab_token=$4
gitlab_domain=${gitlab_url##*//}

if [[ ! $gitlab_url == *"//"* ]]; then
    error "<gitlab-url> must contain a protocol"
    usage
    exit 2
fi

if [ -z $gitolite_base_uri ]; then
    gitolite_base_uri=${gitolite_admin_uri%%:*}
fi

test -z "$gitolite_base_uri" && { error "cannot figure out gitolite base uri"; exit 1; }


# directories
cwd=$(cd $(dirname $0); pwd)
glwd=$cwd/tmp/gitolite-admin


mkdir "$cwd/tmp" 2>/dev/null

# get repository list
set -e
log "gitolite_admin: retrieving repo list"
if [ -d $glwd ]; then
    log "gitolite-admin: found"
else
    log "gitolite-admin@gitolite: download from $gitolite_admin_uri"
    git clone $gitolite_admin_uri "$glwd"
fi
repos=$(sed -n 's/^repo\s\+\(.\+\)$/\1/p' $glwd/conf/gitolite.conf | grep -v gitolite-admin)

# migrate repositories
count=$(set -- $repos; echo $#)
index=0
for lite_repo in $repos; do
    ((++index))
    if [ $interactive -eq 1 ]; then
        read -p "Do you want to migrate repo '$lite_repo'? [Yn] " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            continue
        fi
    fi

    log "($index/$count) $lite_repo"

    lab_repo=$lite_repo
    if [[ ! $lab_repo =~ ^[a-zA-Z0-9_\.-]+$ ]]; then
        log "$lite_repo: invalid characters in gitolite name, replacing them with dash for gitlab"
        lab_repo=$(echo $lite_repo | sed 's/[^a-zA-Z0-9_\.-]/-/g')
    fi

    if [ -f $cwd/tmp/${lab_repo}-migrated ]; then
        success "$lite_repo: already migrated"
        continue
    fi

    clone_repo $lite_repo $lab_repo
    create_repo $lite_repo $lab_repo
    push_repo $lite_repo $lab_repo
    clean_repo $lab_repo
done
