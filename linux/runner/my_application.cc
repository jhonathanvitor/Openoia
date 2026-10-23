#include "my_application.h"

#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <string>
#include <unistd.h>
#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"

typedef void* (* fn_app_indicator_new_with_path)(const char*, const char*, int, const char*);
typedef void (* fn_app_indicator_set_status)(void*, int);
typedef void (* fn_app_indicator_set_menu)(void*, GtkMenu*);
typedef void (* fn_app_indicator_set_title)(void*, const char*);
typedef void (* fn_app_indicator_set_icon_full)(void*, const char*, const char*);
typedef void (* fn_app_indicator_set_secondary_activate_target)(void*, GtkWidget*);

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
  GtkWindow* window;
  gboolean has_tray_indicator;
  gboolean force_quit;
  void* indicator;
  fn_app_indicator_set_icon_full indicator_set_icon_full;
  GtkWidget* item_status;
  gboolean is_showing_connected;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

static std::string resolve_icon_dir() {
  const char* appdir = getenv("APPDIR");
  if (appdir && appdir[0] != '\0') {
    std::string p = std::string(appdir) + "/usr/share/vpn-openoia";
    if (access((p + "/vpn-openoia.png").c_str(), R_OK) == 0) {
      return p;
    }
  }
  const char* home = getenv("HOME");
  if (home && home[0] != '\0') {
    std::string p = std::string(home) + "/.local/share/icons/hicolor/256x256/apps";
    if (access((p + "/vpn-openoia.png").c_str(), R_OK) == 0) {
      return p;
    }
  }
  return "/usr/share/icons/hicolor/256x256/apps";
}

static void request_stop_vpn_for_current_pid() {
  int ret = system("sudo -n /usr/local/bin/vpn-openoia-root-helper --disconnect >/dev/null 2>&1");
  (void)ret;
}

static gboolean poll_vpn_state_cb(gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  if (!self->has_tray_indicator || !self->indicator || !self->indicator_set_icon_full) {
    return G_SOURCE_CONTINUE;
  }

  const char* home = getenv("HOME");
  if (!home) return G_SOURCE_CONTINUE;

  char state_path[512];
  snprintf(state_path, sizeof(state_path), "%s/.config/vpn-openoia/run/state_%d", home, (int)getpid());

  gboolean connected = FALSE;
  FILE* f = fopen(state_path, "r");
  if (f) {
    char buf[64] = {0};
    if (fgets(buf, sizeof(buf) - 1, f)) {
      if (strncmp(buf, "CONNECTED", 9) == 0) {
        connected = TRUE;
      }
    }
    fclose(f);
  }

  if (connected != self->is_showing_connected) {
    self->is_showing_connected = connected;
    if (connected) {
      self->indicator_set_icon_full(self->indicator, "vpn-openoia-connected", "VPN Openoia - Conectado");
      if (self->item_status) {
        gtk_menu_item_set_label(GTK_MENU_ITEM(self->item_status), "🟢 Conectado");
      }
    } else {
      self->indicator_set_icon_full(self->indicator, "vpn-openoia-disconnected", "VPN Openoia - Desconectado");
      if (self->item_status) {
        gtk_menu_item_set_label(GTK_MENU_ITEM(self->item_status), "⚪ Desconectado");
      }
    }
  }

  return G_SOURCE_CONTINUE;
}

static void present_main_window(MyApplication* self) {
  if (self && self->window) {
    gtk_widget_show(GTK_WIDGET(self->window));
    gtk_window_deiconify(self->window);
    gtk_window_present(self->window);
  }
}

static gboolean present_main_window_idle(gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  present_main_window(self);
  return G_SOURCE_REMOVE;
}

static void on_tray_show_window(GtkMenuItem* item, gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  present_main_window(self);
}

static gboolean finish_quit_cb(gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  if (self->window) {
    gtk_widget_destroy(GTK_WIDGET(self->window));
    self->window = nullptr;
  }
  g_application_quit(G_APPLICATION(self));
  return G_SOURCE_REMOVE;
}

static void on_tray_quit_app(GtkMenuItem* item, gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  self->force_quit = TRUE;
  request_stop_vpn_for_current_pid();
  g_timeout_add(1200, finish_quit_cb, self);
}

// Intercept D-Bus org.kde.StatusNotifierItem Activate (triggered by double-click on Ubuntu Top Bar icon)
static GDBusMessage* on_sni_dbus_filter(GDBusConnection* connection,
                                        GDBusMessage* message,
                                        gboolean incoming,
                                        gpointer user_data) {
  if (!incoming) {
    return message;
  }
  if (g_dbus_message_get_message_type(message) == G_DBUS_MESSAGE_TYPE_METHOD_CALL) {
    const gchar* iface = g_dbus_message_get_interface(message);
    const gchar* member = g_dbus_message_get_member(message);
    if (g_strcmp0(iface, "org.kde.StatusNotifierItem") == 0) {
      if (g_strcmp0(member, "Activate") == 0) {
        g_idle_add(present_main_window_idle, user_data);
        GDBusMessage* reply = g_dbus_message_new_method_reply(message);
        g_dbus_connection_send_message(connection, reply, G_DBUS_SEND_MESSAGE_FLAGS_NONE, nullptr, nullptr);
        g_object_unref(reply);
        g_object_unref(message);
        return nullptr;
      }
      if (g_strcmp0(member, "ProvideXdgActivationToken") == 0) {
        GDBusMessage* reply = g_dbus_message_new_method_reply(message);
        g_dbus_connection_send_message(connection, reply, G_DBUS_SEND_MESSAGE_FLAGS_NONE, nullptr, nullptr);
        g_object_unref(reply);
        g_object_unref(message);
        return nullptr;
      }
    }
  }
  return message;
}

// Intercept window close (X button): hide to Ubuntu Top Bar instead of quitting
static gboolean on_window_delete_event(GtkWidget* widget, GdkEvent* event, gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  if (self->has_tray_indicator && !self->force_quit) {
    gtk_widget_hide(widget);
    return TRUE;
  }
  request_stop_vpn_for_current_pid();
  return FALSE;
}

static void setup_top_bar_indicator(MyApplication* self) {
  void* handle = dlopen("libayatana-appindicator3.so.1", RTLD_LAZY);
  if (!handle) {
    handle = dlopen("libappindicator3.so.1", RTLD_LAZY);
  }
  if (!handle) {
    self->has_tray_indicator = FALSE;
    return;
  }

  auto indicator_new_with_path = (fn_app_indicator_new_with_path)dlsym(handle, "app_indicator_new_with_path");
  auto indicator_set_status = (fn_app_indicator_set_status)dlsym(handle, "app_indicator_set_status");
  auto indicator_set_menu = (fn_app_indicator_set_menu)dlsym(handle, "app_indicator_set_menu");
  auto indicator_set_title = (fn_app_indicator_set_title)dlsym(handle, "app_indicator_set_title");
  self->indicator_set_icon_full = (fn_app_indicator_set_icon_full)dlsym(handle, "app_indicator_set_icon_full");
  auto indicator_set_secondary_target =
      (fn_app_indicator_set_secondary_activate_target)dlsym(handle, "app_indicator_set_secondary_activate_target");

  if (!indicator_new_with_path || !indicator_set_status || !indicator_set_menu) {
    self->has_tray_indicator = FALSE;
    return;
  }

  std::string icon_dir = resolve_icon_dir();
  void* indicator = indicator_new_with_path(
      "vpn-openoia", "vpn-openoia-disconnected", 0, icon_dir.c_str());
  if (!indicator) {
    self->has_tray_indicator = FALSE;
    return;
  }
  self->indicator = indicator;
  self->is_showing_connected = FALSE;

  if (indicator_set_title) {
    indicator_set_title(indicator, "Openoia");
  }
  indicator_set_status(indicator, 1);

  GtkWidget* menu = gtk_menu_new();

  self->item_status = gtk_menu_item_new_with_label("⚪ Desconectado");
  gtk_widget_set_sensitive(self->item_status, FALSE);
  gtk_menu_shell_append(GTK_MENU_SHELL(menu), self->item_status);

  GtkWidget* sep0 = gtk_separator_menu_item_new();
  gtk_menu_shell_append(GTK_MENU_SHELL(menu), sep0);

  GtkWidget* item_show = gtk_menu_item_new_with_label("Abrir Openoia");
  g_signal_connect(item_show, "activate", G_CALLBACK(on_tray_show_window), self);
  gtk_menu_shell_append(GTK_MENU_SHELL(menu), item_show);

  GtkWidget* sep = gtk_separator_menu_item_new();
  gtk_menu_shell_append(GTK_MENU_SHELL(menu), sep);

  GtkWidget* item_quit = gtk_menu_item_new_with_label("Sair");
  g_signal_connect(item_quit, "activate", G_CALLBACK(on_tray_quit_app), self);
  gtk_menu_shell_append(GTK_MENU_SHELL(menu), item_quit);

  gtk_widget_show_all(menu);
  indicator_set_menu(indicator, GTK_MENU(menu));

  if (indicator_set_secondary_target) {
    indicator_set_secondary_target(indicator, item_show);
  }

  GDBusConnection* bus = g_bus_get_sync(G_BUS_TYPE_SESSION, nullptr, nullptr);
  if (bus) {
    g_dbus_connection_add_filter(bus, on_sni_dbus_filter, self, nullptr);
    g_object_unref(bus);
  }

  self->has_tray_indicator = TRUE;
  g_timeout_add(350, poll_vpn_state_cb, self);
}

static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);

  if (self->window != nullptr) {
    present_main_window(self);
    return;
  }

  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));
  self->window = window;

  std::string icon_file = resolve_icon_dir() + "/vpn-openoia.png";
  if (access(icon_file.c_str(), R_OK) == 0) {
    gtk_window_set_icon_from_file(window, icon_file.c_str(), nullptr);
  } else {
    gtk_window_set_icon_name(window, "vpn-openoia");
  }

  gboolean use_header_bar = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, "Openoia");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "Openoia");
  }

  gtk_window_set_default_size(window, 1140, 720);
  gtk_window_set_position(window, GTK_WIN_POS_CENTER);

  setup_top_bar_indicator(self);
  g_signal_connect(window, "delete-event", G_CALLBACK(on_window_delete_event), self);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  gdk_rgba_parse(&background_color, "#0B1120");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

static void my_application_startup(GApplication* application) {
  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

static void my_application_shutdown(GApplication* application) {
  request_stop_vpn_for_current_pid();
  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {
  self->window = nullptr;
  self->has_tray_indicator = FALSE;
  self->force_quit = FALSE;
  self->indicator = nullptr;
  self->indicator_set_icon_full = nullptr;
  self->item_status = nullptr;
  self->is_showing_connected = FALSE;
}

MyApplication* my_application_new() {
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     G_APPLICATION_DEFAULT_FLAGS, nullptr));
}
