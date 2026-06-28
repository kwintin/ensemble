import os

def ping(host):
    os.system("ping -c 1 " + host)   # host flows straight into a shell
