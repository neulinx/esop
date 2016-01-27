FROM centos:6

MAINTAINER Gary Hai "gary@XL59.com"

# update to latest version of centos6
RUN yum -y update

# install sshd
RUN yum -y install openssh-server
# generate default configuration.
RUN service sshd start
RUN service sshd stop

# very simple password for root
RUN echo "root:root" | chpasswd

# install development envirenment
RUN yum -y install gcc autoconf automake gcc-c++ libtool tar git subversion

#export ssh server port
EXPOSE 22

CMD /usr/sbin/sshd -D
