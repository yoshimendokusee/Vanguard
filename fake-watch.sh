#!/usr/bin/env bash
# Pretend to be a rescue watch sending one pre-arrival report to the hospital hub.
# Backup for the demo if the watch can't reach the router, and a quick way to
# test the hub on its own.
# Usage: ./fake-watch.sh [hub-url]
# The report is stamped with the current minute, so running it twice within the
# same minute is a duplicate (the hub skips it); a minute later it's a new patient.
HUB=${1:-http://localhost:3000}
NOW=$(date -u +%Y-%m-%dT%H:%M:00.000Z)
curl -sS -X POST "$HUB/api/sync-triage" -H 'Content-Type: application/json' -d '{
  "watchId": "W-TEST",
  "reports": [{
    "localId": 1,
    "location": "Barangay Arnaldo",
    "injuries": "Drowning, Unconscious",
    "triage": "Immediate",
    "patientCount": 2,
    "ageGroup": "Child",
    "etaMinutes": 10,
    "rawText": "Dalawang bata, nalunod at walang malay, sa Barangay Arnaldo, sampung minuto papunta sa ospital.",
    "createdAt": "'"$NOW"'"
  }]
}'
echo
