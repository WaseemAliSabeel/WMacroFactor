# WMacroFactor APP

WMacroFactor App is an AI-assisted Diet Coach that helps in keeping track of your meal intake and trends. Stay Conscious of your macros!



## Pre-Installation Steps

Go to Gemini Studio and Create Your Own ```Gemini API KEY```
This will need to be updated in the Named Credential post-installation and is essential for the app to make callouts to Gemini.


## How to Install 

Login to your Own DEV ORG / Trailhead playground (production instance). 
First Follow the pre-installation steps, then Install the app's Unmanaged package using below link -
[Version 1](https://login.salesforce.com/packaging/installPackage.apexp?p0=04tak000000oqOP)

And then Follow the post-installation steps below


## Post-Installation Steps

As a System Admin yourself, kindly assign yourself the Permission Set "WMacroFactor User"

Three jobs need scheduling after install
Run this below script once in Developer Console ->  Execute Anonymous Apex in the target org:

```
WMF_MealRetrySweep.reschedule(); // Meal retry sweep to auto-retry failed Gemini callouts
WMF_MealImagePurge.scheduleDaily(); // image purge to delete historical files attached to meals and free up storage
WMF_MealReminderBatch.scheduleHourly(); // reminder batch to send automated reminder to users to log their meals
```
Setup -> Named Credential -> Input the value here from your own Gemini API KEY