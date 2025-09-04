# Upchud
> File upload service; without stage 4 retardation.

### Shilling points 🚀:
* Minimal dependencies
* CLI friendly
* Web friendly
* Optional random upload name mangling
* Easy to configure
* Small codebase
* Traubisoda

### Depedencies
* Lighttpd
* Tcl (base installation)

### Architecture
```
                                                  || Storage ||
             +-----------+       +------------+   || ~~~~~~~ ||  +---------+
Clinet ----> | Arbitrary | ====> | CGI script | --|| XXXXXXX ||--| Cleaner |
             |  Server   |       +------------+   || XXXXXXX ||  +---------+
             +-----------+                        || XXXXXXX ||
```

Any webserver that supports CGI/fastCGI will work.
Lighttpd is recommended, but nginx was tested too.

The script does its thing.

To keep your uploads clean,
you either have to set clobbering in the script or
deploy some sort of dedicated cleaner.

The simplest form of cleaner is a cron job that deletes files too old.

### Files
|     File        | Description |
| :-------------- | :---------- |
| lighttpd.conf   | Master lighttpd configuration. Tip: set max upload size here. |
| upchud.tcl      | Master CGI Tcl script. Tip: simply forked by lighttpd; set finer configurations here. |
| Makefile        | Short-hands for common operations. |
| cleaner.crontab | Simple cleaner job. |
| test/*          | Scripts and files used during development. |
| example\_frontend.html          | Simple web front-end for the service. |
| example\_frontend.lighttpd.conf | Serves the example front-end. Tip: you could merge this with the master configuration if you wanted one service. |
| nginx.conf | Example nginx configuration snippet. |

### Usage
Lets get hello-world out-of the way:
```sh
$ make serve &
[1] 15225
lighttpd -D -f lighttpd.conf
$ curl http://localhost:8080 --upload-file test/test.txt
http://localhost:8080/out//n6cru4.txt
$ curl http://localhost:8080/out//n6cru4.txt
Hello World
```

Alternatively I could run.
```sh
$ make serve &
[1] 23895
lighttpd -D -f lighttpd.conf
$ make front &
[2] 24105
lighttpd -D -f example_frontend.lighttpd.conf
```
And I could use the web page (localhost:8081 by default) to perform the same task.

The example frontend is perfectly functional, but is meant to be modified.
Alternatively, you could copy and embed it anywhere else on your site at large.

To learn more about configuration, read the top of `upchud.tcl` and checkout `lighttpd.conf`.

For the mentally Polish, `nginx.conf` is provided,
which is the snippet that was used for the main deployment of upchud.
> [!NOTE]
> You will have to edit the paths because nginx is shit.

### Why?
Because every implementation of this extremely simple thing is flawed.
Common faults I witnessed are:
* CLI is second class with sloppy wrapper scripts and or HTML responses
* No web support, preventing phoneposting
* Horrifically convoluted configuration due to poor isolation of responsibilities
* 6 gorillion dependencies
