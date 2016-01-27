workshop
=================

My workshop on docker.

## Image Creation

This example creates the image with the tag `garyhai/workshop`, but you can change this to use your own username.

```
$ docker build -t="garyhai/workshop" .
```

Alternately, you can run the following if you have *make* installed...

```
$ make
```

You can also specify custom variables by change the Makefile.

You can run it by the following command...

```
$ docker run --name work -it  garyhai/workshop
```
