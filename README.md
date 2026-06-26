# DBGpProxy
**ActiveState**'s DBGp Proxy updated to work with Python3

This DBGpProxy is a modified version of **ActiveState**'s DBGpProxy, 2006 version, to work with Python3.
Tested with Python 3.11

If I remember correctly, ActiveState was the first creator of any debug proxy for PERL, PHP, Ruby, and Python.

Huge thanks to **ActiveState** for creating this product!

This is the only DBGpProxy that has worked for me with Eclipse, which is the IDE I have used almost exclusively since 2010.
The DBGpProxy version from xdebug.org has never worked for me.

The only modifications I made to these files were those necessary to work with Python3 and I take no credit or ownership of this product.
I provide it here because I can not find it on the ActiveState's website.

Perhaps someone else will find it useful.

The file set includes the perl and ruby libraries but neither have been modified so it is not known if they need to be updated for their respective current versions.

Simple usage:

```
bin/pydbgpproxy -i :9000 -o :9001
```

`9000` = port xdebug will connect to DBGpProxy.
`9001` = port your IDE will connect to DBGpProxy.


Configs for XDebug in PHP 8:
```
zend_extension=xdebug.so
xdebug.mode = debug
xdebug.client_port = 9000
xdebug.client_host = localhost  # if DBGpProxy is running on a different host then set that host name or IP address here
xdebug.discover_client_host = true
xdebug.start_with_request = trigger
xdebug.log = /var/log/xdebug.log
xdebug.log_level = 3
;Level	Name	Example
;0	Criticals	Errors in the configuration
;1	Errors	Connection errors
;3	Warnings	Connection warnings
;5	Communication	Protocol messages
;7	Information	Information while connecting
;10	Debug	Breakpoint resolving information
```



Configure your IDE debug port to 9000 and connection to DBGpProxy on port 9001.

Technically your IDE debug port can be set to any valid port number, however, it can become very confusing to utilize your IDE for debug sessions with and without JIT (Just-In-Time) so it is highly recommended to set it the same as `xdebug.client_port`

The file set includes the pydbgp file which I modified in hopes to work with Python3 but I have never used it and can't confirm it works without further modifications needed.

The original MIT license still applies.
