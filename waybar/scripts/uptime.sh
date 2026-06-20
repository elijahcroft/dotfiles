#!/bin/bash

UPTIME_PRETTY=$(uptime -p)
UPTIME_FORMATTED=$(echo "$UPTIME_PRETTY" | sed 's/^up //; s/,*$//')

echo " $UPTIME_FORMATTED"
