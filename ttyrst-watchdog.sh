#!/bin/bash
# Created by Aleksandr Borisenko

DEVICE=/dev/ttyrst-watchdog

WATCHDOG_ACTIVE="YES"
WATCHDOG_TIMER=600  # seconds
SLEEP_TIME=30  # seconds
DEFAULT_LOG_LINES=0  # 0 - show all lines

SCRIPTNAME=`basename $0`
PIDFILE=${PIDFILE-/run/${SCRIPTNAME%.sh}.pid}
E_OPTERROR=65

function fatal_error()
{
	echo `date '+%d-%m-%y %H:%M:%S'` "$1" > /dev/stderr
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
	if ! fuser ${DEVICE} >/dev/null 2>&1; then
		echo "OK"
	fi
}

function device_cmd()
{
	cmd=$1
	if [ ! -z "$2" ]; then
		tw=$2
	else
		tw="1s"
	fi
	if [ -c ${DEVICE} ]; then
		if [ "$(device_wait 10s)" == "OK" ]; then
			exec 3< <(timeout $tw cat <${DEVICE})
			sleep 0.2
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
		else
			echo -n "WAIT"
		fi
	else
		echo -n "NODEV"
	fi
}

function retrieve_log()
{
	re='^[0-9]+$'
	if ! [[ $1 =~ $re ]]; then
		log_lines=${DEFAULT_LOG_LINES}
	else
		log_lines=$1
	fi
    device_cmd "log $log_lines" "10s"
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
		fatal_error "No watchdog device detected!"
	fi
	if [ "$(device_wait 15s)" != "OK" ]; then
		fatal_error "The watchdog device is busy!"
	fi
	stty -F "${DEVICE}" cs8 9600 raw ignbrk noflsh -onlcr -iexten -echo -echoe -echok -echoctl -echoke -crtscts -hupcl
	ts_local=$(timestamp_local)
	ts_device=$(device_cmd "sync $ts_local")
	if [ "$ts_local" != "$ts_device" ]; then
		fatal_error "The watchdog device initialization failed! ($ts_device)"
	fi
}

function update_timer()
{
	status=$(device_cmd "timer "$(timestamp_local)" ${WATCHDOG_TIMER}")
	if [ "$status" != "${WATCHDOG_ACTIVE}" ]; then
		if [ "$status" == "YES" ]; then
			result=$(device_cmd "deactivate")
		elif [ "$status" == "NO" ]; then
			result=$(device_cmd "activate")
		fi
	else
		result="OK"
	fi
	if [ "$result" != "OK" ]; then
		log_message "The watchdog timer was NOT updated properly! ($status)"
	fi
}

function deactivate()
{
	rm -f ${PIDFILE};

	errmsg="The watchdog device was NOT deactivated!"
	if [ "$(device_wait 10s)" != "OK" ]; then
		fatal_error $errmsg
	fi
	status=$(device_cmd "deactivate")
	if [ "$status" != "OK" ]; then
		fatal_error $errmsg
	fi
	exit 0
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
		device_init
		trap deactivate SIGINT SIGTERM
		while true; do
			if is_alive; then
				update_timer
			fi
			sleep ${SLEEP_TIME} & wait $!
    	done
		;;
	"status")
		device_init
		status=$(device_cmd "status")
		if [ ! -z "$status" ]; then 
			IFS=';' read -ra PART <<< "$status"
			echo ${PART[0]}" Status: "${PART[1]}"; Activated: "${PART[2]}"; Timer: "${PART[3]}" sec; Minimum to reset: "${PART[4]}" sec."
		else
			echo "Empty response from device. Please try again."
		fi
		;;
	"reset")
		device_init
		status=$(device_cmd "reset" "10s")
		if [ "$status" != "OK" ]; then
			echo "It is most likely that the device was not reset properly. Please try again."
		fi
		;;
	"log")
		device_init
		retrieve_log $2
		;;
	*)
		echo "Unknown argument: $1." > /dev/stderr
		usage
		;;
esac

exit 0
