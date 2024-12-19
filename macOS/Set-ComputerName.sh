#!/bin/bash

# Get the currently logged in user
currentUser=$(stat -f%Su /dev/console)
# Get the Serial Number of the Computer
sn=$(system_profiler SPHardwareDataType | awk '/Serial/ {print $4}')
# Get the device type
deviceType=$(system_profiler SPHardwareDataType | awk '/Model Name/ {print $3}')
#deviceValue=$(if [[ "$deviceType" = "MacBook" ]]; then
#	echo "L"
#	else
#	echo "D"
#	fi)

new_computername="$deviceType-$currentUser-$sn"

if [[ "$currentUser" == "zgadmin" || "$currentUser" == "adeadmin" ]]; then
	currentUser="unassigned"
	#echo $currentUser
else
	echo "Legit user is logged in - continuing.."
    echo "Setting computer name to $new_computername"
fi

identityUser=$(sh /Library/Addigy/auditor-facts/scripts/identity_users | cut -f1 -d '@')
if [[ -n "$identityUser" ]]; then
    currentUser="$identityUser"
fi

# Set the ComputerName, HostName and LocalHostName
scutil --set ComputerName "$new_computername"
scutil --set HostName "$new_computername"
scutil --set LocalHostName "$new_computername"


<<CONDITION
#!/bin/bash

# Get the current computer name
current_hostname=$(scutil --get HostName)
current_computername=$(scutil --get ComputerName)
current_localhostname=$(scutil --get LocalHostName)

# Get the currently logged in user
currentUser=$(stat -f%Su /dev/console)
# Get the Serial Number of the Computer
sn=$(system_profiler SPHardwareDataType | awk '/Serial/ {print $4}')
# Get the device type
deviceType=$(system_profiler SPHardwareDataType | awk '/Model Name/ {print $3}')
deviceValue=$(if [[ "$deviceType" = "MacBook" ]]; then
	echo "L"
	else
	echo "D"
	fi)

new_computername="$deviceValue-$currentUser-$sn"

if [[ "$currentUser" == "zgadmin" || "$currentUser" == "adeadmin" ]]; then
	currentUser="unassigned"
	echo $currentUser
    exit 1
else
	echo "Legit user is logged in - continuing.."
fi

if [[ "$current_computername" == "$new_computername" && "$current_hostname" == "$new_computername" && "$current_localhostname" == "$new_computername" ]]; then
    echo "$new_computername appears to have already been set. Exiting..."
    exit 1
else
    echo "New computer name needed"
    exit 0
fi
CONDITION