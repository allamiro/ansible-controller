# Sourced by /etc/bash.bashrc. Never run for command or protocol sessions,
# including an explicitly interactive `bash -ic command` invocation.
case $- in
  *i*)
    if [ -z "${BASH_EXECUTION_STRING:-}" ] && [ -z "${ANSIBLE_CONTROLLER_SUPPORT_NOTICE_SHOWN:-}" ]; then
      /usr/local/bin/controller-support || :
      export ANSIBLE_CONTROLLER_SUPPORT_NOTICE_SHOWN=1
    fi
    ;;
esac
