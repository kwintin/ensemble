import yaml

def load_config(user_text):
    # full loader can construct arbitrary Python objects from untrusted input
    return yaml.load(user_text)
