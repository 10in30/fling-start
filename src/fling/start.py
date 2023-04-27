from collections import UserDict
from typing import Any, List
from flask import (
    Flask,
    Blueprint,
    render_template,
    render_template_string,
    redirect,
    request,
)
import pip
import importlib
from os import environ as osenv
from dotenv import load_dotenv


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


class Environ(UserDict):
    MISSING_KEYS: List = []

    def __init__(self, *args, **kwargs):
        kwargs.pop("app")
        load_dotenv()
        keys = {}
        keys.update(**osenv)
        keys.update(**kwargs)
        super().__init__(*args, **keys)

    def ensure_keys(self, list_of_keys):
        """Make sure all the environment keys are available.
        If not, dump to the admin interface to capture them."""
        for key in list_of_keys:
            if not osenv.get(key):
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


@start.route("/admin", methods=["GET", "POST"])
def admin_home():
    if request.form:
        for key in request.form:
            environ[key] = request.form[key]
        environ.save_to_env()
        return "OK! Now restart"
    return render_template_string(
        """
        {% extends "base.html" %}
        {% block content %}
            <h1> Admin </h1>
            {% if missing_keys %}
            <h4>Looks like you're missing some important keys...</h4>
            <form method="post" action="/admin">
            {% for key in missing_keys %}
                {{key}} : <input type="text" name="{{ key }}"/><br/>
            {% endfor %}
            <input type="submit" name="Save Keys and Tokens" />
            </form>
            {% endif %}
        {% endblock %} """,
        missing_keys=environ.MISSING_KEYS,
    )


app = Flask("starter")
app.register_blueprint(start)

environ = Environ(app=app)


def start_app(main_func):
    app.add_url_rule("/main", view_func=main_func)
    app.run()


EXPORTS = [app, render_template_string, install_everything, environ, start_app]
