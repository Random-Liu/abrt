/*
 * Copyright 2007, Intel Corporation
 * Copyright 2009, Red Hat Inc.
 *
 * This file is part of Abrt.
 *
 * This program file is free software; you can redistribute it and/or modify it
 * under the terms of the GNU General Public License as published by the
 * Free Software Foundation; version 2 of the License.
 *
 * This program is distributed in the hope that it will be useful, but WITHOUT
 * ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
 * FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License
 * for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program in a file named COPYING; if not, write to the
 * Free Software Foundation, Inc.,
 * 51 Franklin Street, Fifth Floor,
 * Boston, MA 02110-1301 USA
 *
 * Authors:
 *      Anton Arapov <anton@redhat.com>
 *      Arjan van de Ven <arjan@linux.intel.com>
 */

#include "abrtlib.h"
#include "KerneloopsSysLog.h"

#include <list>
#include <assert.h>

/*
 * This limits the number of oopses we'll submit per session;
 * it's important that this is bounded to avoid feedback loops
 * for the scenario where submitting an oopses causes a warning/oops
 */
#define MAX_OOPS 16

CSysLog::CSysLog() :
	m_nFoundOopses(0)
{}

void CSysLog::QueueOops(char *data, char *version)
{
	if (m_nFoundOopses > MAX_OOPS)
		return;

	COops m_NewOops;
	m_NewOops.m_sData = data;
	m_NewOops.m_sVersion = version;

	m_OopsQueue.push_back(m_NewOops);
	m_nFoundOopses++;
}

void CSysLog::ClearOopsList()
{
	m_OopsQueue.clear();
}

const std::list<COops>& CSysLog::GetOopsList()
{
	return m_OopsQueue;
}


/*
 * extract_version tries to find the kernel version in given data
 */
static int extract_version(const char *linepointer, char *version)
{
	int ret;

	ret = 0;
	if ((strstr(linepointer, "Pid") != NULL)
	 || (strstr(linepointer, "comm") != NULL)
	 || (strstr(linepointer, "CPU") != NULL)
	 || (strstr(linepointer, "REGS") != NULL)
	 || (strstr(linepointer, "EFLAGS") != NULL)
	) {
		char* start;
		char* end;

		start = strstr((char*)linepointer, "2.6.");
		if (start) {
			end = strchrnul(start, ' ');
			strncpy(version, start, end-start);
			ret = 1;
		}
	}

	if (!ret)
		strncpy(version, "undefined", 9);

	return ret;
}

/*
 * extract_oops tries to find oops signatures in a log
 */
struct line_info {
	char *ptr;
	char level;
};
#define REALLOC_CHUNK 1000
int CSysLog::ExtractOops(char *buffer, size_t buflen)
{
	char *c;
	enum { maybe, no, yes } syslog_format = maybe;
	int linecount = 0;
	int lines_info_alloc = 0;
	struct line_info *lines_info = NULL;

	/* Split buffer into lines */

	if (buflen != 0)
		buffer[buflen - 1] = '\n';  /* the buffer usually ends with \n, but let's make sure */
	c = buffer;
	while (c < buffer + buflen) {
		char v, linelevel;
		int len = 0;
		char *c9;
		char *linepointer;

		c9 = (char*)memchr(c, '\n', buffer + buflen - c); /* a \n will always be found */
		assert(c9);
		len = c9 - c;

		/* in /var/log/messages, we need to strip the first part off, upto the 3rd ':' */
		if (syslog_format == yes
		 || (syslog_format == maybe
		     && len > sizeof("Jul  4 11:11:41")
		     && c[3] == ' ' && c[6] == ' ' && c[9] == ':' && c[12] == ':'
		     && (v = (c[5] | c[7]|c[8] | c[10]|c[11] | c[13]|c[14])) <= '9'
		     && v >= '0'
		     && (v = (c[5] & c[7]&c[8] & c[10]&c[11] & c[13]&c[14])) <= '9'
		     && v >= '0'
		    )
		) {
			/* It's syslog file, not a bare dmesg */
			syslog_format = yes;

			char *c2;
			int i;

			/* skip non-kernel lines */
			c2 = (char*)memmem(c, len, "kernel:", 7);
			if (!c2)
				c2 = (char*)memmem(c, len, "abrt:", 5);
			if (!c2)
				goto next_line;

			/* skip to message in "Jan 01 01:23:45 hostname kernel: message" */
			for (i = 0; i < 3; i++) {
				c = (char*)memchr(c, ':', len);
				if (!c)
					goto next_line;
				c++;
				len = c9 - c;
			}
			c++;
			len--;
		} else if (len) {
			syslog_format = no;
		}

		linepointer = c;
		linelevel = 0;
		/* store and remove kernel log level */
		if (len >= 3 && *c == '<' && *(c+2) == '>') {
			linelevel = *(c+1);
			c += 3;
			len -= 3;
			linepointer = c;
		}
		/* remove jiffies time stamp counter if present */
		if (*c == '[') {
			char *c2, *c3;
			c2 = (char*)memchr(c, '.', len);
			c3 = (char*)memchr(c, ']', len);
			if (c2 && c3 && (c2 < c3) && (c3-c) < 14 && (c2-c) < 8) {
				c = c3 + 1;
				if (*c == ' ')
					c++;
				len = c9 - c;
				linepointer = c;
			}
		}

		assert(c + len == c9);
		*c9 = '\0'; /* turn the \n into a string termination */

		/* if we see our own marker, we know we submitted everything upto here already */
		if (len >= 4 && memmem(linepointer, len, "Abrt", 4)) {
			linecount = 0;
			lines_info_alloc = 0;
			free(lines_info);
			lines_info = NULL;
		}

		if (linecount >= lines_info_alloc) {
			lines_info_alloc += REALLOC_CHUNK;
			lines_info = (line_info*)xrealloc(lines_info,
					lines_info_alloc * sizeof(struct line_info));
		}
		lines_info[linecount].ptr = linepointer;
		lines_info[linecount].level = linelevel;
		linecount++;
next_line:
		c = c9 + 1;
	}

	/* Analyze lines */

	int i;
	char prevlevel = 0;
	int oopsstart = -1;
	int oopsend;
	int inbacktrace = 0;
	int oopsesfound = 0;
	oopsend = linecount;

	i = 0;
	while (i < linecount) {
		char *c = lines_info[i].ptr;

		if (c == NULL) {
			i++;
			continue;
		}
		if (oopsstart < 0) {
			/* find start-of-oops markers */
			if (strstr(c, "general protection fault:"))
				oopsstart = i;
			if (strstr(c, "BUG:"))
				oopsstart = i;
			if (strstr(c, "kernel BUG at"))
				oopsstart = i;
			if (strstr(c, "do_IRQ: stack overflow:"))
				oopsstart = i;
			if (strstr(c, "RTNL: assertion failed"))
				oopsstart = i;
			if (strstr(c, "Eeek! page_mapcount(page) went negative!"))
				oopsstart = i;
			if (strstr(c, "near stack overflow (cur:"))
				oopsstart = i;
			if (strstr(c, "double fault:"))
				oopsstart = i;
			if (strstr(c, "Badness at"))
				oopsstart = i;
			if (strstr(c, "NETDEV WATCHDOG"))
				oopsstart = i;
			if (strstr(c, "WARNING:") &&
			    !strstr(c, "appears to be on the same physical disk"))
				oopsstart = i;
			if (strstr(c, "Unable to handle kernel"))
				oopsstart = i;
			if (strstr(c, "sysctl table check failed"))
				oopsstart = i;
			if (strstr(c, "------------[ cut here ]------------"))
				oopsstart = i;
			if (strstr(c, "list_del corruption."))
				oopsstart = i;
			if (strstr(c, "list_add corruption."))
				oopsstart = i;
			if (strstr(c, "Oops:") && i >= 3)
				oopsstart = i-3;
#if DEBUG
			/* debug information */
			if (oopsstart >= 0) {
				printf("Found start of oops at line %i\n", oopsstart);
				printf("    start line is -%s-\n", lines_info[oopsstart].ptr);
				if (oopsstart != i)
					printf("    trigger line is -%s-\n", c);
			}
#endif
			/* try to find the end marker */
			if (oopsstart >= 0) {
				int i2;
				i2 = i+1;
				while (i2 < linecount && i2 < (i+50)) {
					if (strstr(lines_info[i2].ptr, "---[ end trace")) {
						inbacktrace = 1;
						i = i2;
						break;
					}
					i2++;
				}
			}
		}

		/* a calltrace starts with "Call Trace:" or with the " [<.......>] function+0xFF/0xAA" pattern */
		if (oopsstart >= 0 && strstr(lines_info[i].ptr, "Call Trace:"))
			inbacktrace = 1;

		else if (oopsstart >= 0 && inbacktrace == 0 && strlen(lines_info[i].ptr) > 8) {
			char *c1, *c2, *c3;
			c1 = strstr(lines_info[i].ptr, ">]");
			c2 = strstr(lines_info[i].ptr, "+0x");
			c3 = strstr(lines_info[i].ptr, "/0x");
			if (lines_info[i].ptr[0] == ' '
			 && lines_info[i].ptr[1] == '['
			 && lines_info[i].ptr[2] == '<'
			 && c1 && c2 && c3
			) {
				inbacktrace = 1;
			}
		}

		/* try to see if we're at the end of an oops */
		else if (oopsstart >= 0 && inbacktrace > 0) {
			char c2, c3;
			c2 = lines_info[i].ptr[0];
			c3 = lines_info[i].ptr[1];

			/* line needs to start with " [" or have "] ["*/
			if ((c2 != ' ' || c3 != '[')
			 && strstr(lines_info[i].ptr, "] [") == NULL
			 && strstr(lines_info[i].ptr, "--- Exception") == NULL
			 && strstr(lines_info[i].ptr, "    LR =") == NULL
			 && strstr(lines_info[i].ptr, "<#DF>") == NULL
			 && strstr(lines_info[i].ptr, "<IRQ>") == NULL
			 && strstr(lines_info[i].ptr, "<EOI>") == NULL
			 && strstr(lines_info[i].ptr, "<<EOE>>") == NULL
			) {
				oopsend = i-1;
			}

			/* oops lines are always more than 8 long */
			if (strlen(lines_info[i].ptr) < 8)
				oopsend = i-1;
			/* single oopses are of the same loglevel */
			if (lines_info[i].level != prevlevel)
				oopsend = i-1;
			/* The Code: line means we're done with the backtrace */
			if (strstr(lines_info[i].ptr, "Code:") != NULL)
				oopsend = i;
			if (strstr(lines_info[i].ptr, "Instruction dump::") != NULL)
				oopsend = i;
			/* if a new oops starts, this one has ended */
			if (strstr(lines_info[i].ptr, "WARNING:") != NULL && oopsstart != i)
				oopsend = i-1;
			if (strstr(lines_info[i].ptr, "Unable to handle") != NULL && oopsstart != i)
				oopsend = i-1;
			/* kernel end-of-oops marker */
			if (strstr(lines_info[i].ptr, "---[ end trace") != NULL)
				oopsend = i;

			if (oopsend <= i) {
				int q;
				int len;
				int is_version;
				char *oops;
				char *version;

				len = 2;
				for (q = oopsstart; q <= oopsend; q++)
					len += strlen(lines_info[q].ptr) + 1;

				oops = (char*)xzalloc(len);
				version = (char*)xzalloc(len);

				is_version = 0;
				for (q = oopsstart; q <= oopsend; q++) {
					if (!is_version)
						is_version = extract_version(lines_info[q].ptr, version);
					strcat(oops, lines_info[q].ptr);
					strcat(oops, "\n");
				}
				/* too short oopses are invalid */
				if (strlen(oops) > 100) {
					QueueOops(oops, version);
					oopsesfound++;
				}
				oopsstart = -1;
				inbacktrace = 0;
				oopsend = linecount;
				free(oops);
				free(version);
			}
		}
		prevlevel = lines_info[i].level;
		i++;
		if (oopsstart > 0 && i-oopsstart > 50) {
			oopsstart = -1;
			inbacktrace = 0;
			oopsend = linecount;
		}
		if (oopsstart > 0 && !inbacktrace && i-oopsstart > 30) {
			oopsstart = -1;
			inbacktrace = 0;
			oopsend = linecount;
		}
	}
	if (oopsstart >= 0)  {
		int q;
		int len;
		int is_version;
		char *oops;
		char *version;

		oopsend = i-1;

		len = 2;
		while (oopsend > 0 && lines_info[oopsend].ptr == NULL)
			oopsend--;
		for (q = oopsstart; q <= oopsend; q++)
			len += strlen(lines_info[q].ptr) + 1;

		oops = (char*)xzalloc(len);
		version = (char*)xzalloc(len);

		is_version = 0;
		for (q = oopsstart; q <= oopsend; q++) {
			if (!is_version)
				is_version = extract_version(lines_info[q].ptr, version);
			strcat(oops, lines_info[q].ptr);
			strcat(oops, "\n");
		}
		/* too short oopses are invalid */
		if (strlen(oops) > 100) {
			QueueOops(oops, version);
			oopsesfound++;
		}
		oopsstart = -1;
		inbacktrace = 0;
		oopsend = linecount;
		free(oops);
		free(version);
	}

fail:
	free(lines_info);
	return oopsesfound;
}
