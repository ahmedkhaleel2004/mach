#!/usr/bin/env python3
"""How long new mail takes to reach Mach once the mail service has it. The one benchmark that touches real mail.

    bench/live/latency.py outlook <seed.json> [runs]          seed: [{"refreshToken":…, "clientId":…}]
    bench/live/latency.py gmail <client.json> <token.json> [runs]

Each run sends the account one message from itself (so no phone is told about it), watches the service until
the message is in the inbox, and watches the running app's database (read only) until it is there too. The time
between those two is Mach's own: the relay hearing of it, telling the app, and the app fetching it. Every test
message is removed again (Outlook: for good; Gmail: to the bin, which is as far as Mach's permission goes).
Prints numbers only. MACH_DB picks the database (default: the installed app's).
"""
import base64, json, os, sqlite3, statistics, sys, time, urllib.error, urllib.parse, urllib.request

DB = os.environ.get("MACH_DB", os.path.expanduser("~/Library/Application Support/Mach/mail.sqlite"))


def http(method, url, token, body=None, raw=False):
    data = body if raw or body is None else json.dumps(body).encode()
    request = urllib.request.Request(url, data=data, method=method, headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            text = response.read()
            return response.status, json.loads(text) if text else {}
    except urllib.error.HTTPError as error:
        return error.code, {}


def refresh(address, form):
    request = urllib.request.Request(address, urllib.parse.urlencode(form).encode())
    return json.load(urllib.request.urlopen(request, timeout=30))["access_token"]


def in_app(subject):
    connection = sqlite3.connect("file:" + urllib.parse.quote(DB) + "?mode=ro", uri=True, timeout=1)
    try:
        return connection.execute("SELECT 1 FROM message WHERE subject = ? AND labelIds LIKE '%INBOX%' LIMIT 1", (subject,)).fetchone() is not None
    except sqlite3.OperationalError:
        return False
    finally:
        connection.close()


def run(send, arrived, cleanup, runs):
    waits, totals = [], []
    for index in range(runs):
        subject = "Mach latency test %d-%d" % (time.time(), index)
        sent = time.time()
        send(subject)
        at_service = at_app = None
        last_asked = 0
        while time.time() - sent < 90 and at_app is None:
            now = time.time()
            if at_service is None and now - last_asked > 0.3:
                last_asked = now
                if arrived(subject): at_service = time.time()
            if in_app(subject): at_app = time.time()
            time.sleep(0.03)
        if at_app is None or at_service is None:
            print(json.dumps({"run": index, "error": "never arrived" if at_service is None else "the app never showed it in 90 s"}))
        else:
            # The app can win the race with this script's own looking; that counts as no wait at all.
            waits.append(max(0.0, at_app - at_service))
            totals.append(at_app - sent)
            print(json.dumps({"run": index, "service_to_app_s": round(waits[-1], 2), "send_to_app_s": round(totals[-1], 2)}))
        time.sleep(4)
        cleanup(subject)
        time.sleep(2)
    if waits:
        print(json.dumps({"metric": "live-latency", "runs": len(waits), "service_to_app_median_s": round(statistics.median(waits), 2),
                          "service_to_app_max_s": round(max(waits), 2), "send_to_app_median_s": round(statistics.median(totals), 2)}))


def outlook(seed_path, runs):
    seed = json.load(open(seed_path))[0]
    token = refresh("https://login.microsoftonline.com/common/oauth2/v2.0/token",
                    {"client_id": seed["clientId"], "grant_type": "refresh_token", "refresh_token": seed["refreshToken"]})
    graph = "https://graph.microsoft.com/v1.0"
    me = http("GET", graph + "/me?$select=mail,userPrincipalName", token)[1]
    address = me.get("mail") or me["userPrincipalName"]

    def send(subject):
        http("POST", graph + "/me/sendMail", token, {"message": {"subject": subject, "body": {"contentType": "Text", "content": "Timing only."},
                                                                  "toRecipients": [{"emailAddress": {"address": address}}]}, "saveToSentItems": False})

    def find(subject, folder=None):
        where = "/me/mailFolders/%s/messages" % folder if folder else "/me/messages"
        query = urllib.parse.urlencode({"$filter": "subject eq '%s'" % subject, "$select": "id", "$top": "10"})
        return [m["id"] for m in http("GET", graph + where + "?" + query, token)[1].get("value", [])]

    def cleanup(subject):
        for message in find(subject):
            http("POST", graph + "/me/messages/%s/permanentDelete" % message, token)

    run(send, lambda subject: bool(find(subject, "inbox")), cleanup, runs)


def gmail(client_path, token_path, runs):
    client = json.load(open(client_path))
    client = client.get("installed") or client
    saved = json.load(open(token_path))
    form = {"client_id": client.get("client_id") or client.get("clientId"), "grant_type": "refresh_token",
            "refresh_token": saved.get("refreshToken") or saved.get("refresh_token")}
    secret = client.get("client_secret") or client.get("clientSecret")
    if secret: form["client_secret"] = secret
    token = refresh("https://oauth2.googleapis.com/token", form)
    api = "https://gmail.googleapis.com/gmail/v1/users/me"
    address = http("GET", api + "/profile", token)[1]["emailAddress"]

    def send(subject):
        text = "From: %s\r\nTo: %s\r\nSubject: %s\r\n\r\nTiming only.\r\n" % (address, address, subject)
        http("POST", api + "/messages/send", token, {"raw": base64.urlsafe_b64encode(text.encode()).decode()})

    def find(subject, extra=""):
        query = urllib.parse.urlencode({"q": 'subject:"%s" %s' % (subject, extra), "maxResults": "10"})
        return [m["id"] for m in http("GET", api + "/messages?" + query, token)[1].get("messages", [])]

    def cleanup(subject):
        for message in find(subject):
            http("POST", api + "/messages/%s/trash" % message, token)

    run(send, lambda subject: bool(find(subject, "in:inbox")), cleanup, runs)


if __name__ == "__main__":
    if len(sys.argv) >= 3 and sys.argv[1] == "outlook":
        outlook(sys.argv[2], int(sys.argv[3]) if len(sys.argv) > 3 else 5)
    elif len(sys.argv) >= 4 and sys.argv[1] == "gmail":
        gmail(sys.argv[2], sys.argv[3], int(sys.argv[4]) if len(sys.argv) > 4 else 5)
    else:
        print(__doc__)
        sys.exit(2)
