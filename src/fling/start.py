from collections import UserDict
import os
import signal
from typing import Any, List
from flask_bootstrap import Bootstrap5
from flask import (
    Flask,
    Blueprint,
    render_template,
    render_template_string,
    redirect,
    request,
)
from flask_caching import Cache
from flask_babel import Babel
from flask_admin import Admin
import pip
import importlib
from os import environ as osenv
from dotenv import load_dotenv


app = Flask("starter")
cache = Cache(config={'CACHE_TYPE': 'SimpleCache'})
cache.init_app(app)


def install(package):
    if hasattr(pip, "main"):
        pip.main(["install", package])
    else:
        pip._internal.main(["install", package])


def install_everything(list_of_packages):
    for package, modulename in list_of_packages:
        try:
            importlib.import_module(f"{modulename}")
        except Exception:
            install(package)


start = Blueprint(
    "fling-starter",
    __name__,
    static_folder="static/start",
    static_url_path="/static/start",
    template_folder="templates",
)


@start.route("/")
def index():
    return render_template("start/index.html")


@start.route("/x3d")
def x3d():
    return render_template("start/x3d.html")


def admin_bounce():
    return redirect("/admin")
    # return """<script>window.location.href='/admin';</script>"""


class Environ(UserDict):
    MISSING_KEYS: List = []

    def __init__(self, *args, **kwargs):
        kwargs.pop("app")
        load_dotenv()
        keys = {}
        keys.update(**kwargs)
        super().__init__(*args, **keys)

    def ensure_keys(self, list_of_keys):
        """Make sure all the environment keys are available.
        If not, dump to the admin interface to capture them."""
        for key in list_of_keys:
            if osenv.get(key):
                self.__setitem__(key, osenv[key])
            else:
                # TODO(JMC): If this is running headless, aka PROD, then fail?
                print(f"Missing a key! {key}")
                self.MISSING_KEYS.append(key)
        if self.MISSING_KEYS:
            app.add_url_rule("/main", view_func=admin_bounce)
            return False
        return True

    def save_to_env(self):
        with open(".env", "w+") as env_file:
            for key in self.data:
                env_file.write(f"{key}={self.data[key]}\n")

    def __setitem__(self, key, value):
        key = key.upper()
        return super().__setitem__(key, value)

    def __getitem__(self, key: Any) -> Any:
        key = key.upper()
        storeditem = super().__getitem__(key)
        if not storeditem:
            return osenv.get(key)
        return storeditem


pending_restart = False


@start.route("/update_keys", methods=["POST"])
def admin_keys():
    global pending_restart
    if request.form:
        for key in request.form:
            environ[key] = request.form[key]
        environ.save_to_env()
        pending_restart = True
        return """<meta http-equiv="refresh" content="5;URL='/admin'"/>OK! Now to restart..."""


babel = Babel(app)
app.config["FLASK_ADMIN_SWATCH"] = "darkly"

app.register_blueprint(start)
admin = Admin(app, name="Admin", template_mode="bootstrap3")
bootstrap = Bootstrap5(app)
environ = Environ(app=app)


@app.after_request
def response_processor(response):
    # Prepare all the local variables you need since the request context
    # will be gone in the callback function

    @response.call_on_close
    def process_after_request():
        global pending_restart
        if pending_restart:
            print("Gonna reboot here...")
            import pathlib

            pathlib.Path("reboot.py").touch(mode=0o666, exist_ok=True)
            # signal.raise_signal(signal.SIGABRT)

    return response


def start_app(main_func, domain_name=None):
    if not environ.MISSING_KEYS:
        app.add_url_rule("/main", view_func=main_func)

    @app.context_processor
    def inject_globals():
        return dict(domain_name=domain_name, missing_keys=environ.MISSING_KEYS)

    if __name__ == "__main__":
        app.run()


EXPORTS = [app, render_template_string, install_everything, environ, start_app]
