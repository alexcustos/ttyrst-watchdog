#!/bin/bash
# Created by Aleksandr Borisenko

DEVICE=/dev/ttyrst-watchdog

WATCHDOG_ACTIVE="YES"
WATCHDOG_TIMER=600  # seconds
SLEEP_TIME=30  # seconds
DEFAULT_LOG_LINES=0  # 0 - show all lines

SCRIPTNAME=`basename $0`
PIDFILE=${PIDFILE-/run/${SCRIPTNAME%.sh}.pid}
LOCKPID=0
E_OPTERROR=65

function fatal_error()
{
	echo `date '+%d-%m-%y %H:%M:%S'` "$1"
	exit 1
}

function log_message()
{
	echo `date '+%d-%m-%y %H:%M:%S'` "$1"
}

function device_wait()
{
	if [ ! -z "$1" ]; then
		timeout $1 bash -c "while fuser ${DEVICE} >/dev/null 2>&1; do true; done"
	fi
	sleep `bc <<< "scale=4; ${RANDOM}/32767/4"`  # 0.25 max
	if ! fuser ${DEVICE} >/dev/null 2>&1; then
		echo "OK"
	fi
}

function device_cmd()
{
	cmd=$1
	if [ -r /dev/fd/3 ]; then
		# echo "CMD: $cmd" >>/tmp/ttyrst-watchdog.log
		echo "$cmd" >${DEVICE}
		if [[ $cmd == log* ]]; then
			while read log_line <&3; do
				log_line=$(echo -n "$log_line" | tr -d '\r\n')
				if [ "$log_line" == "DONE" ]; then
					break
				fi
				echo "$log_line"
			done
		else
			echo -n $(head -n1 <&3 | tr -d '\r\n')
		fi
		exec 3>&-
	fi
}

function timestamp_local()
{
	ts_date=$(date +%s)
	IFS=":" read hh mm < <(date +%:z)
	ts_offset=$(($hh*3600+$mm*60))
	echo $(($ts_date+$ts_offset))
}

function device_init()
{
	if [ ! -c "${DEVICE}" ]; then
		$1 "No watchdog device detected!"
	fi
	stty -F "${DEVICE}" cs8 9600 raw ignbrk noflsh -onlcr -iexten -echo -echoe -echok -echoctl -echoke -crtscts
}

function device_lock()
{
	if [ ! -z "$2" ]; then
		tw=$2
	else
		tw="1s"
	fi
	if [ -c ${DEVICE} ]; then
		if [ "$(device_wait 15s)" == "OK" ]; then
			exec 3< <(timeout $tw cat <${DEVICE})
			LOCKPID=$(ps -eo pid,args | grep "timeout $tw cat" | grep -v grep | awk '{ print $1 }')
			sleep 0.2
			return 0  # true
		else
			$1 "The watchdog device is busy!"
		fi
	else
		$1 "No watchdog device detected!"
	fi
	return 1  # false
}

function device_release()
{
	if [ "$LOCKPID" -gt "0" ]; then
		kill $LOCKPID
		LOCKPID=0
	fi
}

function device_check()
{
	ts_local=$(timestamp_local)
	ts_device=$(device_cmd "sync $ts_local")
	if [ "$ts_local" != "$ts_device" ]; then
		fatal_error "The watchdog device initialization failed!"
	fi
}

function device_ready()
{
	if [ ! -z "$1" ]; then
		tw=$1
	else
		tw="1s"
	fi
	device_init fatal_error
	if device_lock fatal_error $tw; then
		device_check
	fi
	return 0  # true
}

function update_timer()
{
	if device_lock log_message; then  # 1s
		result="FAIL"
		status=$(device_cmd "timer "$(timestamp_local)" ${WATCHDOG_TIMER}")
		if [ "$status" != "${WATCHDOG_ACTIVE}" ]; then
			if [ "$status" == "YES" ]; then
				result=$(device_cmd "deactivate")
			elif [ "$status" == "NO" ]; then
				result=$(device_cmd "activate")
			fi
		elif [ "$status" == "YES" ] || [ "$status" == "NO" ]; then
			result="OK"
		fi
		if [ "$result" != "OK" ]; then
			device_init log_message
			log_message "The watchdog timer was NOT updated properly!"
		fi
	fi
}

function deactivate()
{
	rm -f ${PIDFILE};

	device_init log_message
	if device_lock log_message; then  # 1s
		status=$(device_cmd "deactivate")
		if [ "$status" == "OK" ]; then
			exit 0
		fi
	fi
	echo "deactivate" >${DEVICE}
	fatal_error "It is most likely that the watchdog was NOT deactivated properly!"
}

function single_instance()
{
	if [ -e ${PIDFILE} ] && kill -0 `cat ${PIDFILE}`; then
		fatal_error "The watchdog daemon already running!"
	fi
	echo $$ > ${PIDFILE}
}

function is_alive()
{
	return 0  # true
}

function usage()
{
	echo ""
	echo "USAGE:"
	echo "    $SCRIPTNAME [start | status | reset | log]"
	echo ""
	echo "OPTIONS:"
	echo "    start         - activate the watchdog device and enter main loop."
	echo "                    ^C, SIGTERM deactivate the watchdog and terminate script."
	echo "    status        - show  status information from the watchdog device."
	echo "    reset         - clear EEPROM and reboot the device to set the watchdog to initial state."
	echo "    log <lines>   - show number of lines of the log from the watchdog device."
	echo "                    DEFAULT: ${DEFAULT_LOG_LINES} (0 - show all lines)."
	exit $E_OPTERROR
}

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
	echo "Wrong number of arguments specified."
	usage
fi

case "$1" in
	"start")
		single_instance
		device_ready  # 1s
		trap deactivate SIGINT SIGTERM
		while true; do
			if is_alive; then
				update_timer
			fi
			sleep ${SLEEP_TIME} & wait $!
    	done
		;;
	"status")
		device_ready  # 1s
		status=$(device_cmd "status")
		if [ ! -z "$status" ]; then
			IFS=';' read -ra PART <<< "$status"
			echo ${PART[0]}" Status: "${PART[1]}"; Activated: "${PART[2]}"; Timer: "${PART[3]}" sec; Minimum to reset: "${PART[4]}" sec."
		else
			echo "Empty response from device. Please try again."
		fi
		;;
	"reset")
		exec 2>/dev/null
		device_ready "10s"
		status=$(device_cmd "reset")
		device_release
		if [ "$status" != "OK" ]; then
			echo "It is most likely that the device was NOT reset properly. Please try again."
		fi
		;;
	"log")
		exec 2>/dev/null
		device_ready "10s"
		if [[ $2 =~ ^[0-9]+$ ]]; then
			log_lines=$2
		else
			log_lines=${DEFAULT_LOG_LINES}
		fi
		device_cmd "log $log_lines"
		device_release
		;;
	*)
		echo "Unknown argument: $1."
		usage
		;;
esac

exit 0
