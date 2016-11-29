#!/bin/bash
# vim: dict=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   runtest.sh of reporter-systemd-journal
#   Description: Verify reporter-systemd-journal functionality
#   Author: Matej Habrnal <mhabrnal@redhat.com>
#
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   Copyright (c) 2016 Red Hat, Inc. All rights reserved.
#
#   This program is free software: you can redistribute it and/or
#   modify it under the terms of the GNU General Public License as
#   published by the Free Software Foundation, either version 3 of
#   the License, or (at your option) any later version.
#
#   This program is distributed in the hope that it will be
#   useful, but WITHOUT ANY WARRANTY; without even the implied
#   warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
#   PURPOSE.  See the GNU General Public License for more details.
#
#   You should have received a copy of the GNU General Public License
#   along with this program. If not, see http://www.gnu.org/licenses/.
#
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

. /usr/share/beakerlib/beakerlib.sh
. ../aux/lib.sh

TEST="reporter-systemd-journal"
PACKAGE="abrt"

# generated by journalctl --new-id128
CATALOG_MSG_ID="1bea0b0f98524411b3696309155f34db"
JOURNAL_CATALOG_PATH="/usr/lib/systemd/catalog/abrt_test.catalog"
SYSLOG_ID="abrt_reporter_systemd_journal_testing"


# $1 reporter parameters
# $2 journal parameters
# $3 log file name
# $4 Array shouldn't contain
function check()
{
    REPORTER_PARAMS=$1
    shift
    JOURNAL_PARAMS=$1
    shift
    LOG_FILE=$1.log
    shift

    # ignore of previous reports
    sleep 2
    SINCE=$(date +"%Y-%m-%d %T")
    rlLog "Start date time stamp $SINCE"
    sleep 2

    # reporting
    reporter-systemd-journal -d problem_dir -s $SYSLOG_ID $REPORTER_PARAMS
    sleep 2

    # list journal
    journalctl $JOURNAL_PARAMS "SYSLOG_IDENTIFIER=$SYSLOG_ID" --since="$SINCE" 2>&1 | tee $LOG_FILE

    # lines before string 'NULL' shoudl be placed in journal log and lines
    # after string 'NULL' shouldn't
    array=( "$@" )
    SHOULD_CONTAIN=true
    for line in "${array[@]}"; do
        if [ "$line" = "NULL" ]; then
            SHOULD_CONTAIN=false
            continue
        fi

        if [ $SHOULD_CONTAIN = true ]; then
            rlAssertGrep "$line" $LOG_FILE
        else
            rlAssertNotGrep "$line" $LOG_FILE
        fi
    done
}

rlJournalStart
    rlPhaseStartSetup
        LANG=""
        export LANG

        rpm -q libreport-plugin-systemd-journal || rlDie "Package 'libreport-plugin-systemd-journal' is not installed."

cat > $JOURNAL_CATALOG_PATH << EOF
-- $CATALOG_MSG_ID
Subject: ABRT testing
Defined-By: ABRT
Support: https://bugzilla.redhat.com/
Documentation: man:abrt(1)
@PROBLEM_REPORT@
ABRT TESTING
EOF

        # update catalog messages
        journalctl --update-catalog

        TmpDir=$(mktemp -d)
        cp -R problem_dir $TmpDir
        pushd $TmpDir

cat > abrt_format.conf << EOF
%summary:: REPORTER MAIN MESSAGE

DESCRIPTION PART
EOF
    rlPhaseEnd

    rlPhaseStartTest "sanity"
        rlRun "reporter-systemd-journal --help &> null"
        rlRun "reporter-systemd-journal --help 2>&1 | grep 'Usage:'"
    rlPhaseEnd

    rlPhaseStartTest "default reporting"
        # catalog message
        check_array=( \
            # should be in log
            'Process /usr/bin/urxvtd was killed by signal 11 (SIGSEGV)' \
            'NULL' \
            # shouldn't be in log
            '-- Subject: ABRT testing' \
            '-- Support: https://bugzilla.redhat.com/' \
            '-- Documentation: man:abrt(1)' \
            '-- DESCRIPTION PART' \
            '-- ABRT TESTING' \
        )
        check "" "-x" "default" "${check_array[@]}"
    rlPhaseEnd

    rlPhaseStartTest "only formatting file"
        # catalog message
        check_array=( \
            # should be in log
            'REPORTER MAIN MESSAGE' \
            'NULL' \
            # shouldn't be in log
            'Process /usr/bin/urxvtd was killed by signal 11 (SIGSEGV)' \
            '-- Subject: ABRT testing' \
            '-- Support: https://bugzilla.redhat.com/' \
            '-- Documentation: man:abrt(1)' \
            '-- DESCRIPTION PART' \
            '-- ABRT TESTING' \
        )
        check "-F abrt_format.conf" "-x" "only_formatting_file" "${check_array[@]}"
    rlPhaseEnd

    rlPhaseStartTest "only message id"
        # catalog message
        check_array=( \
            # should be in log
            'Process /usr/bin/urxvtd was killed by signal 11 (SIGSEGV)' \
            '-- Subject: ABRT testing' \
            '-- Support: https://bugzilla.redhat.com/' \
            '-- Documentation: man:abrt(1)' \
            '-- ABRT TESTING' \
            'NULL' \
            # shouldn't be in log
            'REPORTER MAIN MESSAGE' \
            '-- DESCRIPTION PART' \
        )
        check "-m $CATALOG_MSG_ID" "-x" "only_message_id" "${check_array[@]}"
    rlPhaseEnd

    rlPhaseStartTest "message id and formatting conf"
        # catalog message
        check_array=( \
            # should be in log
            'REPORTER MAIN MESSAGE' \
            '-- Subject: ABRT testing' \
            '-- Support: https://bugzilla.redhat.com/' \
            '-- Documentation: man:abrt(1)' \
            '-- DESCRIPTION PART' \
            '-- ABRT TESTING' \
            'NULL' \
            # shouldn't be in log
            'Process /usr/bin/urxvtd was killed by signal 11 (SIGSEGV)' \
        )
        check "-m $CATALOG_MSG_ID -F abrt_format.conf" "-x" "message_id_formatting_file" "${check_array[@]}"
    rlPhaseEnd

    rlPhaseStartTest "parameter --dump NONE"
        # journal fields
        check_array=( \
            # should be in log
            '"MESSAGE" : "REPORTER MAIN MESSAGE"' \
            '"SYSLOG_IDENTIFIER" : "abrt_reporter_systemd_journal_testing"' \
            '"PROBLEM_BINARY" : "urxvtd"' \
            '"PROBLEM_REASON" : "Process /usr/bin/urxvtd was killed by signal 11 (SIGSEGV)"' \
            '"PROBLEM_CRASH_FUNCTION" : "rxvt_term::selection_delimit_word"' \
            '"PROBLEM_REPORT" : "\\nDESCRIPTION PART\\n"' \
            '"PROBLEM_PID" : "1234"' \
            '"PROBLEM_EXCEPTION_TYPE" : "exception_type"' \
            'NULL' \
            # shouldn't be in log
            '"PROBLEM_CMDLINE" : "urxvtd -q -o -f"' \
            '"PROBLEM_COMPONENT" : "rxvt-unicode"' \
            '"PROBLEM_UID" : "502"' \
            '"PROBLEM_PKG_NAME" : "package name"' \
            '"PROBLEM_PKG_VERSION" : "3"' \
            '"PROBLEM_PKG_RELEASE" : "33"' \
            '"PROBLEM_PKG_FINGERPRINT" : "xxxx-xxxx-xxx"' \
            '"PROBLEM_REPORTED_TO" : "bugzilla"' \
        )
        check "--dump NONE -F abrt_format.conf" "-o json-pretty" "dump_none" "${check_array[@]}"
    rlPhaseEnd

    rlPhaseStartTest "parameter --dump ESSENTIAL"
        # journal fields
        check_array=( \
            # should be in log
            '"MESSAGE" : "REPORTER MAIN MESSAGE"' \
            '"SYSLOG_IDENTIFIER" : "abrt_reporter_systemd_journal_testing"' \
            '"PROBLEM_BINARY" : "urxvtd"' \
            '"PROBLEM_REASON" : "Process /usr/bin/urxvtd was killed by signal 11 (SIGSEGV)"' \
            '"PROBLEM_CRASH_FUNCTION" : "rxvt_term::selection_delimit_word"' \
            '"PROBLEM_REPORT" : "\\nDESCRIPTION PART\\n"' \
            '"PROBLEM_PID" : "1234"' \
            '"PROBLEM_EXCEPTION_TYPE" : "exception_type"' \
            # essential fields
            '"PROBLEM_CMDLINE" : "urxvtd -q -o -f"' \
            '"PROBLEM_COMPONENT" : "rxvt-unicode"' \
            '"PROBLEM_UID" : "502"' \
            '"PROBLEM_PKG_NAME" : "package name"' \
            '"PROBLEM_PKG_VERSION" : "3"' \
            '"PROBLEM_PKG_RELEASE" : "33"' \
            '"PROBLEM_PKG_FINGERPRINT" : "xxxx-xxxx-xxx"' \
            '"PROBLEM_REPORTED_TO" : "bugzilla"' \
            '"PROBLEM_TYPE" : "CCpp"' \
            'NULL' \
            # shouldn't be in log
            '"PROBLEM_DSO_LIST" : "/lib64/libcrypt-2.14.so glibc-2.14-4.x86_64 (Fedora Project) 1310382635"' \
            '"PROBLEM_BACKTRACE_RATING" : "1"' \
            '"POBLEM_HOSTNAME" : "fluffy"' \
            '"PROBLEM_DUPHASH" : "bbfe66399cc9cb8ba647414e33c5d1e4ad82b511"' \
            '"PROBLEM_BACKTRACE" : "testing backtrace"' \
            '"PROBLEM_OS_RELEASE" : "Fedora release 15 (Lovelock)"' \
            '"PROBLEM_KERNEL" : "2.6.38.8-35.fc15.x86_64"' \
        )
        check "--dump ESSENTIAL -F abrt_format.conf" "-o json-pretty" "dump_essential" "${check_array[@]}"
    rlPhaseEnd

    rlPhaseStartTest "parameter --dump FULL"
        # journal fields
        check_array=( \
            # should be in log
            '"MESSAGE" : "REPORTER MAIN MESSAGE"' \
            '"SYSLOG_IDENTIFIER" : "abrt_reporter_systemd_journal_testing"' \
            '"PROBLEM_BINARY" : "urxvtd"' \
            '"PROBLEM_REASON" : "Process /usr/bin/urxvtd was killed by signal 11 (SIGSEGV)"' \
            '"PROBLEM_CRASH_FUNCTION" : "rxvt_term::selection_delimit_word"' \
            '"PROBLEM_REPORT" : "\\nDESCRIPTION PART\\n"' \
            '"PROBLEM_PID" : "1234"' \
            '"PROBLEM_EXCEPTION_TYPE" : "exception_type"' \
            # essential fields
            '"PROBLEM_CMDLINE" : "urxvtd -q -o -f"' \
            '"PROBLEM_COMPONENT" : "rxvt-unicode"' \
            '"PROBLEM_UID" : "502"' \
            '"PROBLEM_PKG_NAME" : "package name"' \
            '"PROBLEM_PKG_VERSION" : "3"' \
            '"PROBLEM_PKG_RELEASE" : "33"' \
            '"PROBLEM_PKG_FINGERPRINT" : "xxxx-xxxx-xxx"' \
            '"PROBLEM_REPORTED_TO" : "bugzilla"' \
            '"PROBLEM_TYPE" : "CCpp"' \
            # full fields
            '"PROBLEM_DSO_LIST" : "/lib64/libcrypt-2.14.so glibc-2.14-4.x86_64 (Fedora Project) 1310382635"' \
            '"PROBLEM_BACKTRACE_RATING" : "1"' \
            '"PROBLEM_HOSTNAME" : "fluffy"' \
            '"PROBLEM_DUPHASH" : "bbfe66399cc9cb8ba647414e33c5d1e4ad82b511"' \
            '"PROBLEM_BACKTRACE" : "testing backtrace"' \
            '"PROBLEM_OS_RELEASE" : "Fedora release 15 (Lovelock)"' \
            '"PROBLEM_KERNEL" : "2.6.38.8-35.fc15.x86_64"' \
            'NULL' \
            # shouldn't be in log
        )
        check "--dump FULL -F abrt_format.conf" "-o json-pretty" "dump_full" "${check_array[@]}"
    rlPhaseEnd
    rlPhaseStartCleanup
        rlBundleLogs abrt $(ls *.log)
        rlRun "rm -f $JOURNAL_CATALOG_PATH"
        journalctl --update-catalog
        popd # TmpDir
        rm -rf $TmpDir
    rlPhaseEnd
    rlJournalPrintText
rlJournalEnd