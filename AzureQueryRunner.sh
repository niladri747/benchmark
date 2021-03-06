#!/bin/sh

set -e

export AZURE_ACCOUNT=fivetran
export AZURE_USER=developers
if [ ! -f ~/.azure_password ]; then
  echo "No password set, do this:"
  echo "echo {mypassword} > ~/.azure_password"
  exit 1
fi
export AZURE_PWD=`cat ~/.azure_password`

if [ -z "$AZURE_WAREHOUSE" ] || \
   [ -z "$AZURE_DATABASE" ]; then
  echo "missing \$AZURE_WAREHOUSE or \$AZURE_DATABASE" 1>&2
  AZURE_WAREHOUSE=tpcds
  AZURE_DATABASE=tpcds
fi

tempdir=`mktemp -d _work_XXXXXXXXXX`

cleanup() {
  rm -rf "$tempdir" 2>/dev/null || :
}
trap cleanup TERM KILL

runsql() {
  args="-l 10 -N -m-1 -j -I -p"
  if [ "$1" = "bare" ]; then
    args="-N -I"
    shift 1
  fi
  sqlcmd $args \
    -S ${AZURE_WAREHOUSE}.database.windows.net \
    -U "developers@${AZURE_WAREHOUSE}" \
    -P "${AZURE_PWD}" \
    -d "${AZURE_DATABASE}" \
    $@
}

upload() {
  args="-q -c -t| -e error.log"
  if ! bcp \
    $@ \
    $args \
    -S ${AZURE_WAREHOUSE}.database.windows.net \
    -U "developers@${AZURE_WAREHOUSE}" \
    -P "${AZURE_PWD}" \
    -d "${AZURE_DATABASE}"
  then
    echo "Failed to load with $@"
    cat error.log
    exit 1
  else
    echo "Success loading with $@"
  fi
}

timing() {
  mkfifo $tempdir/outsql

  touch $tempdir/output

  runsql -i "$1" >$tempdir/outsql &
  PID=$!

  cat $tempdir/outsql | {
    while read -r line ; do
      if echo "$line" | grep -q "Clock Time" ; then
        # Example: Clock Time (ms.): total        26  avg   26.0 (38.5 xacts per sec.)
        echo timing: $line 1>&7
        echo "$line" | awk '{print $5 / 1000}'
        break
      elif [ "$verbose" = 1 ]; then
        echo "sqlcmd: $line" 1>&7
      else
        echo $line >> $tempdir/output
      fi
    done
  }

  head -n15 $tempdir/output >&7

  wait $PID
  cleanup
}

if [ "$1" = "timing" ]; then
  time=`timing "$2" 7>&2`
  printf "%s,%.5f\n" "$2" "$time"
elif [ "$1" = "ddl" ]; then
  export verbose=1
  timing "$2" 7>&2
elif [ "$1" = "bcp" ]; then
  shift 1
  upload $@
else
  runsql bare
fi
