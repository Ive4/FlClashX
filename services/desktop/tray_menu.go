package main

import (
	"fmt"

	"fyne.io/systray"
)

type trayProxyMenu struct {
	root    *systray.MenuItem
	testAll *systray.MenuItem
	empty   *systray.MenuItem
	groups  []trayGroupMenu
	labels  map[string]string
	bind    func(*systray.MenuItem, trayActionRequest)
}

type trayGroupMenu struct {
	item   *systray.MenuItem
	test   *systray.MenuItem
	nodes  []*systray.MenuItem
	state  trayGroup
	title  string
	titles []string
}

func newTrayProxyMenu(labels map[string]string, bind func(*systray.MenuItem, trayActionRequest)) *trayProxyMenu {
	menu := &trayProxyMenu{labels: labels, bind: bind}
	menu.root = systray.AddMenuItem(labels["proxies"], "")
	menu.testAll = menu.root.AddSubMenuItem(labels["delayTest"], "")
	bind(menu.testAll, trayActionRequest{Action: "test"})
	menu.empty = menu.root.AddSubMenuItem(labels["proxyGroupEmpty"], "")
	menu.empty.Disable()
	return menu
}

func sameTrayGroupMembers(menus []trayGroupMenu, groups []trayGroup) bool {
	if len(menus) != len(groups) {
		return false
	}
	for index, group := range groups {
		old := menus[index].state
		if old.Name != group.Name || old.Selectable != group.Selectable || len(old.Proxies) != len(group.Proxies) {
			return false
		}
		for node, proxy := range group.Proxies {
			if old.Proxies[node].Name != proxy.Name {
				return false
			}
		}
	}
	return true
}

func setTrayChecked(item *systray.MenuItem, checked bool) {
	if item.Checked() == checked {
		return
	}
	if checked {
		item.Check()
	} else {
		item.Uncheck()
	}
}

func setTrayEnabled(item *systray.MenuItem, enabled bool) {
	if item.Disabled() == !enabled {
		return
	}
	if enabled {
		item.Enable()
	} else {
		item.Disable()
	}
}

func trayProxyTitle(proxy trayProxy, labels map[string]string) string {
	if proxy.Testing {
		return proxy.Name + " · …"
	}
	if proxy.Delay == nil {
		return proxy.Name
	}
	if *proxy.Delay > 0 {
		return fmt.Sprintf("%s · %d ms", proxy.Name, *proxy.Delay)
	}
	if *proxy.Delay == -1 {
		return proxy.Name + " · " + labels["timeout"]
	}
	return proxy.Name + " · " + labels["error"]
}

func (menu *trayProxyMenu) update(state trayMenuState) {
	if !sameTrayGroupMembers(menu.groups, state.Groups) {
		for _, group := range menu.groups {
			group.item.Remove()
		}
		menu.groups = nil
		for _, group := range state.Groups {
			item := menu.root.AddSubMenuItem(group.Name, "")
			test := item.AddSubMenuItem(menu.labels["delayTest"], "")
			menu.bind(test, trayActionRequest{Action: "test", Group: group.Name})
			current := trayGroupMenu{item: item, test: test, state: group, title: group.Name}
			for _, proxy := range group.Proxies {
				node := item.AddSubMenuItemCheckbox(proxy.Name, "", false)
				menu.bind(node, trayActionRequest{Action: "select", Group: group.Name, Proxy: proxy.Name})
				setTrayEnabled(node, group.Selectable)
				current.nodes = append(current.nodes, node)
				current.titles = append(current.titles, proxy.Name)
			}
			menu.groups = append(menu.groups, current)
		}
	}
	if len(state.Groups) == 0 {
		menu.empty.Show()
	} else {
		menu.empty.Hide()
	}
	setTrayEnabled(menu.testAll, !state.Testing && len(state.Groups) != 0)
	for index, group := range state.Groups {
		current := &menu.groups[index]
		title := group.Name
		if group.Now != "" {
			title += " · " + group.Now
		}
		if current.title != title {
			current.item.SetTitle(title)
			current.title = title
		}
		setTrayEnabled(current.test, !state.Testing && len(group.Proxies) != 0)
		for node, proxy := range group.Proxies {
			title := trayProxyTitle(proxy, menu.labels)
			if current.titles[node] != title {
				current.nodes[node].SetTitle(title)
				current.titles[node] = title
			}
			setTrayChecked(current.nodes[node], group.Now == proxy.Name)
		}
		current.state = group
	}
}
