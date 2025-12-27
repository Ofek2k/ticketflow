self.addEventListener("push", (event) => {
  let data = {};
  try { data = event.data ? event.data.json() : {}; } catch (e) {}

  const title = data.title || "TicketFlow";
  const options = {
    body: data.body || "יש עדכון חדש",
    icon: data.icon || "/logo.png",
    badge: data.badge || "/logo.png",
    data: data.url || "/",
  };

  event.waitUntil(self.registration.showNotification(title, options));
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const url = event.notification.data || "/";
  event.waitUntil(
    clients.matchAll({ type: "window", includeUncontrolled: true }).then((wins) => {
      for (const w of wins) {
        if (w.url.includes(url)) return w.focus();
      }
      return clients.openWindow(url);
    })
  );
});
