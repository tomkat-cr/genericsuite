#!/bin/bash
# scripts/update_packages.sh
# 2026-04-20 | CR
# Update all packages in the containing directory

ask_user_to_continue() {
    echo "Do you want to continue (y/n)"
    read answer
    if [ "${answer}" = "n" ]; then
        echo "Aborting..."
        exit
    fi
}

BRANCH="${BRANCH:=develop}"
SUBMODULE="${SUBMODULE:-1}" # 1 = add submodule (default), 0 = clone repository
GIT_USER="${GIT_USER:-tomkat-cr}"
GIT_HOST="${GIT_HOST:-https://github.com}"

PACKAGES_PATH="./packages"

# PACKAGE_LIST is defined in get_package_list.sh
source ./scripts/get_package_list.sh > /dev/null 2>&1

if [ ! -d "${PACKAGES_PATH}" ]; then
    if ! mkdir -p "${PACKAGES_PATH}"; then
        echo "Error: Could not create directory ${PACKAGES_PATH}"
        exit 1
    fi
fi

for PACKAGE in "${PACKAGE_LIST[@]}"; do
    if [ ! -d "${PACKAGES_PATH}/${PACKAGE}" ]; then
        echo ""
        echo "Adding submodule for ${PACKAGE}..."
        if [ "${SUBMODULE}" = "1" ]; then
            if ! git submodule add ${GIT_HOST}/${GIT_USER}/${PACKAGE}.git "${PACKAGES_PATH}/${PACKAGE}"
            then
                echo "Error: Could not add repository '${PACKAGE}' as a git submodule"
                ask_user_to_continue
                echo "Skipping ${PACKAGE}"
                continue
            fi
        else
            echo ""
            echo "Cloning ${PACKAGE}..."
            if ! git clone ${GIT_HOST}/${GIT_USER}/${PACKAGE}.git "${PACKAGES_PATH}/${PACKAGE}"
            then
                echo "Error: Could not clone repository '${PACKAGE}'"
                ask_user_to_continue
                echo "Skipping ${PACKAGE}"
                continue
            fi
        fi
    fi
    echo ""
    echo "Updating ${PACKAGE}..."
    cd "${PACKAGES_PATH}/${PACKAGE}"
    if [ "${STASH}" = "1" ]; then
        echo ""
        echo "Stashing changes for ${PACKAGE}..."
        git stash
    fi
    git fetch -a
    if [ "$BRANCH" != "" ]; then
        echo ""
        echo "Checking-out branch ${BRANCH} for ${PACKAGE}..."
        git checkout "${BRANCH}"
    fi
    git pull
    cd -
done
