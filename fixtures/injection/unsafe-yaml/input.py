import yaml

def load_config(user_text):
    # UnsafeLoader constructs arbitrary Python objects from untrusted input (RCE)
    return yaml.load(user_text, Loader=yaml.UnsafeLoader)
