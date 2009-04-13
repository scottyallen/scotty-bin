#!/bin/sh

pwd_length=25

DIR=`pwd`

echo $DIR | grep "^$HOME" >> /dev/null

if [ $? -eq 0 ]
then
  CURRDIR=`echo $DIR | awk -F$HOME '{print $2}'`
  newPWD="~$CURRDIR"

  if [ $(echo -n $newPWD | wc -c | tr -d " ") -gt $pwd_length ]
  then
    newPWD="~/..$(echo -n $PWD | sed -e "s/.*\(.\{$pwd_length\}\)/\1/")"
  fi
elif [ "$DIR" = "$HOME" ]
then
  newPWD="~"
elif [ $(echo -n $PWD | wc -c | tr -d " ") -gt $pwd_length ]
then
  newPWD="..$(echo -n $PWD | sed -e "s/.*\(.\{$pwd_length\}\)/\1/")"
else
  newPWD="$(echo -n $PWD)"
fi
echo $newPWD
