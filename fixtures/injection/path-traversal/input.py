def read_user_file(base_dir, user_path):
    # user_path may contain ../ to escape base_dir
    with open(base_dir + "/" + user_path) as f:
        return f.read()
