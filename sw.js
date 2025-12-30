self.addEventListener('push', function(event) {
  const data = event.data.json();
  const options = {
    body: data.body,
    icon: 'https://cdn-icons-png.flaticon.com/512/906/906343.png', // הלוגו
    badge: 'https://cdn-icons-png.flaticon.com/512/906/906343.png',
    data: { url: data.url }
  };
  event.waitUntil(
    self.registration.showNotification(data.title, options)
  );
});

self.addEventListener('notificationclick', function(event) {
  event.notification.close();
  event.waitUntil(
    clients.openWindow(event.notification.data.url)
  );
});