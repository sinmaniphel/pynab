#!/usr/bin/env bash

set -xuo pipefail
trap 's=$?; echo "$0: Error on line "$LINENO": $BASH_COMMAND"; exit $s' ERR
IFS=$'\n\t'

# v1 card : Paris Maker Faire 2018 card, only fits Nabaztag V1. You probably have a v2.
# v2 card : fits Nabaztag V1 and Nabaztag V2. Features a microphone. Button is on GPIO 17.
v1card=0

# travis-chroot : we're building a release image on Travis CI
travis_chroot=0

# test : user wants to run tests (good idea, makes sure sounds and leds are functional)
test=0

# upgrade : this script is invoked from upgrade.sh, typically from the button in the web interface.
upgrade=0

if [ "${1:-}" == "--v1" ]; then
  v1card=1
  shift
fi

if [ "${1:-}" == "travis-chroot" ]; then
  travis_chroot=1
elif [ "${1:-}" == "test" ]; then
  test=1
elif [ "${1:-}" == "upgrade" ]; then
  upgrade=1
  # auto-detect v1 card here.
  if [ `aplay -L | grep -c "hifiberry"` -gt 0 ]; then
    v1card=1
  fi
fi

if [ $travis_chroot -eq 0 -a "`uname -s -m`" != 'Linux armv6l' ]; then
  echo "Installation only planned on Raspberry Pi Zero, will cowardly exit"
  exit 1
fi

if [ $USER == "root" ]; then
  echo "Please run this script as a regular user with sudo privileges"
  exit 1
fi

cd `dirname "$0"`
root_dir=`pwd`

if [ $travis_chroot -eq 0 -a $v1card -eq 0 -a `aplay -L | grep -c "seeed2micvoicec"` -eq 0 ]; then
  if [ `aplay -L | grep -c "hifiberry"` -gt 0 ]; then
    echo "Judging from the sound card, this looks likes a v1 card (Paris Maker Faire 2018)."
    echo "Please double-check and restart this script with --v1"
  else
    echo "Please install and configure sound card driver http://wiki.seeedstudio.com/ReSpeaker_2_Mics_Pi_HAT/"
  fi
  exit 1
fi

if [ $v1card -eq 1 ]; then
  if [ `aplay -L | grep -c "hifiberry"` -eq 0 ]; then
    echo "Please install and configure sound card driver https://support.hifiberry.com/hc/en-us/articles/205377651-Configuring-Linux-4-x-or-higher"
    exit 1
  fi
  sudo touch /etc/nabaztagtagtag_v1
fi

if [ $v1card -eq 0 ]; then
  # v1 card has no mic, no need to install kaldi
  if [ ! -d "/opt/kaldi" ]; then
    echo "Installing precompiled kaldi into /opt"
    wget -O - -q https://github.com/pguyot/kaldi/releases/download/v5.4.1/kaldi-c3260f2-linux_armv6l-vfp.tar.xz | sudo tar xJ -C /
  fi

  if [ ! -d "/opt/kaldi/model/kaldi-generic-en-tdnn_250-r20190227" ]; then
    echo "Installing kaldi model for English from Zamia Speech"
    wget -O - -q https://goofy.zamia.org/zamia-speech/asr-models/kaldi-generic-en-tdnn_250-r20190227.tar.xz | sudo tar xJ -C /opt/kaldi/model/
  fi
fi

if [ ! -d "venv" ]; then
  echo "Creating Python 3 virtual environment"
  pyvenv-3.5 venv
fi

echo "Installing PyPi requirements"
venv/bin/pip install -r requirements.txt

if [ $v1card -eq 0 ]; then
  # v1 card has no mic, no need to install snips
  if [ ! -d "venv/lib/python3.5/site-packages/snips_nlu_fr" ]; then
    echo "Downloading snips_nlu models for French"
    venv/bin/python -m snips_nlu download fr
  fi

  if [ ! -d "venv/lib/python3.5/site-packages/snips_nlu_en" ]; then
    echo "Downloading snips_nlu models for English"
    venv/bin/python -m snips_nlu download en
  fi

  echo "Compiling snips datasets"
  mkdir -p nabd/nlu
  venv/bin/python -m snips_nlu generate-dataset en */nlu/intent_en.yaml > nabd/nlu/nlu_dataset_en.json
  venv/bin/python -m snips_nlu generate-dataset fr */nlu/intent_fr.yaml > nabd/nlu/nlu_dataset_fr.json

  echo "Persisting snips engines"
  venv/bin/snips-nlu train nabd/nlu/nlu_dataset_en.json nabd/nlu/engine_en
  venv/bin/snips-nlu train nabd/nlu/nlu_dataset_fr.json nabd/nlu/engine_fr
fi

trust=`sudo grep local /etc/postgresql/*/main/pg_hba.conf | grep -cE '^local +all +all +trust' || echo -n ''`
if [ $trust -ne 1 ]; then
  echo "Configuring PostgreSQL for trusted access"
  sudo sed -i.orig -E -e 's|^(local +all +all +)peer$|\1trust|' /etc/postgresql/*/main/pg_hba.conf
  trust=`sudo grep local /etc/postgresql/*/main/pg_hba.conf | grep -cE '^local +all +all +trust' || echo -n ''`
  if [ $trust -ne 1 ]; then
    echo "Failed to configure PostgreSQL"
    exit 1
  fi
  if [ $travis_chroot -eq 1 ]; then
    cluster_version=`echo /etc/postgresql/*/main/pg_hba.conf  | sed -E 's|/etc/postgresql/(.+)/(.+)/pg_hba.conf|\1|g'`
    cluster_name=`echo /etc/postgresql/*/main/pg_hba.conf  | sed -E 's|/etc/postgresql/(.+)/(.+)/pg_hba.conf|\2|g'`
    sudo -u postgres /usr/lib/postgresql/${cluster_version}/bin/pg_ctl start -D /etc/postgresql/${cluster_version}/${cluster_name}/
  else
    sudo systemctl restart postgresql
  fi
fi

if [ ! -e '/etc/nginx/sites-enabled/pynab' ]; then
  echo "Installing nginx configuration file"
  if [ -h '/etc/nginx/sites-enabled/default' ]; then
    sudo rm /etc/nginx/sites-enabled/default
  fi
  sudo cp nabweb/nginx-site.conf /etc/nginx/sites-enabled/pynab
  if [ $travis_chroot -eq 0 ]; then
    sudo systemctl restart nginx
  fi
fi

psql -U pynab -c '' 2>/dev/null || {
  echo "Creating PostgreSQL database"
  sudo -u postgres psql -U postgres -c "CREATE USER pynab"
  sudo -u postgres psql -U postgres -c "CREATE DATABASE pynab OWNER=pynab"
  sudo -u postgres psql -U postgres -c "ALTER ROLE pynab CREATEDB"
}

venv/bin/python manage.py migrate
if [ $upgrade -eq 0 ]; then
  venv/bin/django-admin compilemessages
else
  for module in nab*/locale; do
    (
      cd `dirname ${module}`
      ../venv/bin/django-admin compilemessages
    )
  done
fi

if [ $test -eq 1 ]; then
  echo "Running tests"
  sudo venv/bin/pytest
fi

if [ $travis_chroot -eq 1 ]; then
  sudo -u postgres /usr/lib/postgresql/${cluster_version}/bin/pg_ctl stop -D /etc/postgresql/${cluster_version}/${cluster_name}/
fi

# copy service files
for service_file in */*.service ; do
  name=`basename ${service_file}`
  sudo sed -e "s|/home/pi/pynab|${root_dir}|g" < ${service_file} > /tmp/${name}
  sudo mv /tmp/${name} /lib/systemd/system/${name}
  sudo chown root /lib/systemd/system/${name}
  sudo systemctl enable ${name}
done

if [ $travis_chroot -eq 0 ]; then
  sudo systemctl start nabd

  # start services
  for service_file in */*.service ; do
    name=`basename ${service_file}`
    if [ "${name}" != "nabd.service" -a "${name}" != "nabweb.service" ]; then
      sudo systemctl start ${name}
    fi
  done

  sudo systemctl start nabweb.service
fi
