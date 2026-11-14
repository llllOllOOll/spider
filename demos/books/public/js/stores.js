document.addEventListener('alpine:init', () => {

    Alpine.store('toast', {
        show: false,
        message: '',
        type: 'success',
        _timer: null,
        fire(message, type = 'success') {
            clearTimeout(this._timer);
            this.message = message;
            this.type = type;
            this.show = true;
            this._timer = setTimeout(() => { this.show = false; }, 3000);
        },
    });

    Alpine.store('layout', {
        sidebarOpen: false,
        drawerOpen:  false,
        moreOpen:    false,
    });

    Alpine.store('connectivity', {
        online: navigator.onLine,
        init() {
            window.addEventListener('online',  () => { this.online = true; });
            window.addEventListener('offline', () => { this.online = false; });
        },
    });

});
