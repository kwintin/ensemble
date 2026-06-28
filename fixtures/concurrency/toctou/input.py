import os

def ensure_dir(path):
    # check-then-act: another process can create/remove path between the two calls
    if not os.path.exists(path):
        os.mkdir(path)            # races with a concurrent mkdir -> FileExistsError
