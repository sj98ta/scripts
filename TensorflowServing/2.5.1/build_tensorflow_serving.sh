#!/bin/bash
# © Copyright IBM Corporation 2021.
# LICENSE: Apache License, Version 2.0 (http://www.apache.org/licenses/LICENSE-2.0)
#
# Instructions:
# Download build script: wget https://raw.githubusercontent.com/linux-on-ibm-z/scripts/master/TensorflowServing/2.5.1/build_tensorflow_serving.sh
# Execute build script: bash build_tensorflow_serving.sh    (provide -h for help)
#

set -e  -o pipefail

PACKAGE_NAME="tensorflow-serving"
PACKAGE_VERSION="2.5.1"
SOURCE_ROOT="$(pwd)"
USER="$(whoami)"
PATCH_URL="https://raw.githubusercontent.com/linux-on-ibm-z/scripts/master/TensorflowServing/2.5.1/patch"

FORCE="false"
TESTS="false"
LOG_FILE="${SOURCE_ROOT}/logs/${PACKAGE_NAME}-${PACKAGE_VERSION}-$(date +"%F-%T").log"

trap cleanup 0 1 2 ERR

#Check if directory exists
if [ ! -d "$SOURCE_ROOT/logs/" ]; then
   mkdir -p "$SOURCE_ROOT/logs/"
fi


if [ -f "/etc/os-release" ]; then
        source "/etc/os-release"
fi

function prepare() {
        if command -v "sudo" >/dev/null; then
                printf -- 'Sudo : Yes\n' >>"$LOG_FILE"
        else
                printf -- 'Sudo : No \n' >>"$LOG_FILE"
                printf -- 'Install sudo from repository using apt, yum or zypper based on your distro. \n'
                exit 1
        fi

        if [[ "$FORCE" == "true" ]]; then
                printf -- 'Force attribute provided hence continuing with install without confirmation message\n' |& tee -a "$LOG_FILE"
        else
                # Ask user for prerequisite installation
                printf -- "\nAs part of the installation, dependencies would be installed/upgraded. \n"
                while true; do
                        read -r -p "Do you want to continue (y/n) ? :  " yn
                        case $yn in
                        [Yy]*)
                                printf -- 'User responded with Yes. \n' >> "$LOG_FILE"
                                break
                                ;;
                        [Nn]*) exit ;;
                        *) echo "Please provide confirmation to proceed." ;;
                        esac
                done
        fi
}

function cleanup() {
    # Remove artifacts
        rm -rf $SOURCE_ROOT/bazel/bazel-3.7.2-dist.zip
        rm -rf $SOURCE_ROOT/build_bazel.sh

        printf -- "Cleaned up the artifacts\n" | tee -a "$LOG_FILE"

}
function configureAndInstall() {
        printf -- 'Configuration and Installation started \n'

        printf -- "Create symlink for python 3 only environment\n" |& tee -a "$LOG_FILE"
        sudo update-alternatives --install /usr/bin/python python /usr/bin/python3 40

        #Install grpcio
        printf -- "\nInstalling grpcio. . . \n"
        export GRPC_PYTHON_BUILD_SYSTEM_OPENSSL=True
        sudo -E pip3 install grpcio |& tee -a "${LOG_FILE}"

        # Build Bazel
        printf -- '\nBuilding bazel..... \n'
        cd $SOURCE_ROOT
        wget -q https://raw.githubusercontent.com/linux-on-ibm-z/scripts/master/Bazel/3.7.2/build_bazel.sh
        sed -i "s/\"ubuntu-18.04\"/\"ubuntu-18.04\" | \"ubuntu-20.04\" | \"ubuntu-21.04\"/g" build_bazel.sh
        bash build_bazel.sh -y

        export PATH=$SOURCE_ROOT/bazel/output:$PATH
        echo $PATH

        # Build TensorFlow
        printf -- '\nDownload Tensorflow source code..... \n'
        cd $SOURCE_ROOT
        rm -rf tensorflow
        git clone https://github.com/linux-on-ibm-z/tensorflow.git
        cd tensorflow
        git checkout v2.5.0-s390x

        export PYTHON_BIN_PATH="/usr/bin/python3"

        yes "" | ./configure || true

        printf -- '\nBuilding TENSORFLOW..... \n'
        bazel build //tensorflow/tools/pip_package:build_pip_package

        #Build and install TensorFlow wheel
        printf -- '\nBuilding and installing Tensorflow wheel..... \n'
        cd $SOURCE_ROOT/tensorflow
        bazel-bin/tensorflow/tools/pip_package/build_pip_package /tmp/tensorflow_wheel

        if [[ "${DISTRO}" == "ubuntu-18.04" ]]; then
                sudo ln -s /usr/include/locale.h /usr/include/xlocale.h
        fi
        sudo pip3 install /tmp/tensorflow_wheel/tensorflow-2.5.0-cp*-linux_s390x.whl

        #Install Boringssl
        cd $SOURCE_ROOT
        rm -rf boringssl
        wget https://github.com/google/boringssl/archive/80ca9f9f6ece29ab132cce4cf807a9465a18cfac.tar.gz
        tar -zxvf 80ca9f9f6ece29ab132cce4cf807a9465a18cfac.tar.gz
        mv boringssl-80ca9f9f6ece29ab132cce4cf807a9465a18cfac/ boringssl/
        cd boringssl/
        sed -i '/set(ARCH "ppc64le")/a \elseif (${CMAKE_SYSTEM_PROCESSOR} STREQUAL "s390x")\n\ set(ARCH "s390x")' src/CMakeLists.txt
        sed -i '/OPENSSL_PNACL/a \#elif defined(__s390x__)\n\#define OPENSSL_64_BIT' src/include/openssl/base.h

        #Build Tensorflow serving
        printf -- '\nDownload Tensorflow serving source code..... \n'
        cd $SOURCE_ROOT
        rm -rf serving
        git clone https://github.com/tensorflow/serving
        cd serving
        git checkout 2.5.1

        #Apply Patches
        printf -- '\nPatching Tensorflow Serving..... \n'
        wget -O tfs_patch.diff $PATCH_URL/tfs_patch.diff
        sed -i "s?source_root?$SOURCE_ROOT?" tfs_patch.diff
        git apply tfs_patch.diff
        cd $SOURCE_ROOT/tensorflow
        wget -O tf_patch.diff $PATCH_URL/tf_patch.diff
        git apply tf_patch.diff

        printf -- '\nBuilding Tensorflow Serving..... \n'
        cd $SOURCE_ROOT/serving
        bazel --host_jvm_args="-Xms1024m" --host_jvm_args="-Xmx2048m" build --color=yes --curses=yes --host_javabase="@local_jdk//:jdk" --verbose_failures --output_filter=DONT_MATCH_ANYTHING -c opt tensorflow_serving/model_servers:tensorflow_model_server
        sudo pip3 install tensorflow-serving-api==2.5.1

        sudo cp $SOURCE_ROOT/serving/bazel-bin/tensorflow_serving/model_servers/tensorflow_model_server /usr/local/bin

        #Creating model.tflite
        printf -- '\nCreating and replacing default model.tflite..... \n'
        cd $SOURCE_ROOT/tensorflow
        bazel build --host_javabase="@local_jdk//:jdk" //tensorflow/lite/tools/signature:signature_def_utils
        cp -r bazel-bin/tensorflow/lite/tools/signature/* tensorflow/lite/tools/signature/
        sudo rm -rf $(python3 -c "import site; print(\"\\n\".join(site.getsitepackages()))" | head -n 1)/tensorflow/lite/tools
        sudo ln -s $SOURCE_ROOT/tensorflow/tensorflow/lite/tools $(python3 -c "import site; print(\"\\n\".join(site.getsitepackages()))" | head -n 1)/tensorflow/lite/tools

        sudo rm -rf /tmp/saved_model_half_plus_two*
        sudo python $SOURCE_ROOT/serving/tensorflow_serving/servables/tensorflow/testdata/saved_model_half_plus_two.py
        sudo cp /tmp/saved_model_half_plus_two_tflite/model.tflite $SOURCE_ROOT/serving/tensorflow_serving/servables/tensorflow/testdata/saved_model_half_plus_two_tflite/00000123/
        sudo cp /tmp/saved_model_half_plus_two_tflite_with_sigdef/model.tflite $SOURCE_ROOT/serving/tensorflow_serving/servables/tensorflow/testdata/saved_model_half_plus_two_tflite_with_sigdef/00000123/

        mkdir /tmp/parse_example_tflite
        python $SOURCE_ROOT/serving/tensorflow_serving/servables/tensorflow/testdata/parse_example_tflite.py
        cp /tmp/parse_example_tflite/model.tflite $SOURCE_ROOT/serving/tensorflow_serving/servables/tensorflow/testdata/parse_example_tflite/00000123/model.tflite

        # Run Tests
        runTest

        #Cleanup
        cleanup

        printf -- "\n Installation of %s %s was successful \n\n" $PACKAGE_NAME $PACKAGE_VERSION
}

function runTest() {
        set +e
        if [[ "$TESTS" == "true" ]]; then
                printf -- "TEST Flag is set , Continue with running test \n"

                cd $SOURCE_ROOT/serving
                bazel --host_jvm_args="-Xms1024m" --host_jvm_args="-Xmx2048m" test --test_tag_filters=-gpu,-benchmark-test -k --build_tests_only --test_output=errors --verbose_failures -c opt tensorflow_serving/...
                printf -- "Tests completed. \n"

        fi
        set -e
}

function logDetails() {
        printf -- '**************************** SYSTEM DETAILS *************************************************************\n' >>"$LOG_FILE"
        if [ -f "/etc/os-release" ]; then
                cat "/etc/os-release" >>"$LOG_FILE"
        fi

        cat /proc/version >>"$LOG_FILE"
        printf -- '*********************************************************************************************************\n' >>"$LOG_FILE"

        printf -- "Detected %s \n" "$PRETTY_NAME"
        printf -- "Request details : PACKAGE NAME= %s , VERSION= %s \n" "$PACKAGE_NAME" "$PACKAGE_VERSION" |& tee -a "$LOG_FILE"
}

# Print the usage message
function printHelp() {
        echo
        echo "Usage: "
        echo "  bash build_tensorflow_serving.sh  [-d debug] [-y install-without-confirmation] [-t install-with-tests]"
        echo
}

while getopts "h?dyt" opt; do
        case "$opt" in
        h | \?)
                printHelp
                exit 0
                ;;
        d)
                set -x
                ;;
        y)
                FORCE="true"
                ;;
        t)
                TESTS="true"
                ;;
        esac
done

function gettingStarted() {
        printf -- '\n***********************************************************************************************\n'
        printf -- "Getting Started: \n"
        printf -- "To verify, run TensorFlow Serving from command Line : \n"
        printf -- "  $ cd $SOURCE_ROOT  \n"
        printf -- "  $ export TESTDATA=$SOURCE_ROOT/serving/tensorflow_serving/servables/tensorflow/testdata  \n"
        printf -- "  $ tensorflow_model_server --rest_api_port=8501 --model_name=half_plus_two --model_base_path=\$TESTDATA/saved_model_half_plus_two_cpu &  \n"
        printf -- "  $ curl -d '{\"instances\": [1.0, 2.0, 5.0]}'     -X POST http://localhost:8501/v1/models/half_plus_two:predict\n"
        printf -- "Output should look like:\n"
        printf -- "  $ predictions: [2.5, 3.0, 4.5 \n"
        printf -- "  $ ]\n"
        printf -- 'Make sure JAVA_HOME is set and bazel binary is in your path in case of test case execution.'
        printf -- '*************************************************************************************************\n'
        printf -- '\n'
}

###############################################################################################################

logDetails
prepare #Check Prequisites

DISTRO="$ID-$VERSION_ID"
case "$DISTRO" in
"ubuntu-18.04")
        printf -- "Installing %s %s for %s \n" "$PACKAGE_NAME" "$PACKAGE_VERSION" "$DISTRO" |& tee -a "$LOG_FILE"
        printf -- "Installing dependencies... it may take some time.\n"
        sudo apt-get update
        sudo apt-get install sudo wget git unzip zip python3-dev python3-pip pkg-config libhdf5-dev libssl-dev libblas-dev liblapack-dev gfortran -y |& tee -a "${LOG_FILE}"
        sudo ldconfig
        sudo pip3 install --upgrade pip |& tee -a "${LOG_FILE}"
        sudo pip3 install --no-cache-dir numpy==1.19.5 wheel scipy portpicker protobuf==3.13.0 |& tee -a "${LOG_FILE}"
        sudo pip3 install keras_preprocessing --no-deps |& tee -a "${LOG_FILE}"
        configureAndInstall |& tee -a "${LOG_FILE}"
        ;;

"ubuntu-20.04")
        printf -- "Installing %s %s for %s \n" "$PACKAGE_NAME" "$PACKAGE_VERSION" "$DISTRO" |& tee -a "$LOG_FILE"
        printf -- "Installing dependencies... it may take some time.\n"
        sudo apt-get update
        sudo apt-get install sudo wget git unzip zip python3-dev python3-pip pkg-config libhdf5-dev libssl-dev libblas-dev liblapack-dev gfortran -y |& tee -a "${LOG_FILE}"
        sudo ldconfig
        sudo pip3 install --upgrade pip |& tee -a "${LOG_FILE}"
        sudo pip3 install --no-cache-dir numpy==1.19.5 wheel scipy==1.6.3 portpicker protobuf==3.13.0 |& tee -a "${LOG_FILE}"
        sudo pip3 install keras_preprocessing --no-deps |& tee -a "${LOG_FILE}"
        configureAndInstall |& tee -a "${LOG_FILE}"
        ;;

"ubuntu-21.04")
        printf -- "Installing %s %s for %s \n" "$PACKAGE_NAME" "$PACKAGE_VERSION" "$DISTRO" |& tee -a "$LOG_FILE"
        printf -- "Installing dependencies... it may take some time.\n"
        sudo apt-get update
        sudo apt-get install sudo wget git unzip zip python3-dev python3-pip pkg-config libhdf5-dev libssl-dev libblas-dev liblapack-dev gfortran gcc-7 g++-7 -y |& tee -a "${LOG_FILE}"
        sudo ldconfig
        sudo update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-7 60 --slave /usr/bin/g++ g++ /usr/bin/g++-7
        sudo update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-10 40 --slave /usr/bin/g++ g++ /usr/bin/g++-10
        sudo update-alternatives --auto gcc
        sudo pip3 install --upgrade pip |& tee -a "${LOG_FILE}"
        sudo pip3 install --no-cache-dir numpy==1.19.5 wheel scipy==1.6.3 portpicker protobuf==3.13.0 |& tee -a "${LOG_FILE}"
        sudo pip3 install keras_preprocessing --no-deps |& tee -a "${LOG_FILE}"
        configureAndInstall |& tee -a "${LOG_FILE}"
        ;;

*)
        printf -- "%s not supported \n" "$DISTRO" |& tee -a "$LOG_FILE"
        exit 1
        ;;
esac

gettingStarted |& tee -a "${LOG_FILE}"

