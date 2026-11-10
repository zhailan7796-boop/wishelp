#pragma once
#include <windows.h>
#include <dwmapi.h>
#include <algorithm>
#include <cmath>

// Owns a DWM destination only. Source windows are never moved, shown, activated,
// uncloaked or assigned attributes, including when they are minimized.
class PeekPreview {
    HWND host_{},source_{},popup_{};
    HTHUMBNAIL thumbnail_{};
    HINSTANCE module_{};
    RECT destination_{},popupRect_{};
    static LRESULT CALLBACK Procedure(HWND hwnd,UINT msg,WPARAM wparam,LPARAM lparam) {
        if (msg==WM_NCHITTEST) return HTTRANSPARENT;
        if (msg==WM_MOUSEACTIVATE) return MA_NOACTIVATE;
        if (msg==WM_ERASEBKGND) return 1;
        return DefWindowProcW(hwnd,msg,wparam,lparam);
    }
public:
    bool Visible() const { return host_ && IsWindowVisible(host_); }
    HWND Source() const { return source_; }
    HWND Host() const { return host_; }
    HWND Popup() const { return popup_; }
    void Initialize(HINSTANCE module) { module_=module; }
    void Hide() {
        if (host_) ShowWindow(host_,SW_HIDE);
        if (host_) RemovePropW(host_,L"TaskbarFollow.PeekSource");
        if (thumbnail_) DwmUnregisterThumbnail(thumbnail_);
        thumbnail_=nullptr; source_=popup_=nullptr;
    }
    void Shutdown() { Hide(); if (host_) DestroyWindow(host_); host_=nullptr; }
    bool Show(HWND source,DWORD pid,HWND popup,HMONITOR monitor) {
        DWORD currentPid{}; GetWindowThreadProcessId(source,&currentPid);
        if (!IsWindow(source) || currentPid!=pid || !IsWindow(popup)) { Hide(); return false; }
        MONITORINFO info{sizeof(info)};
        if (!GetMonitorInfoW(monitor,&info)) { Hide(); return false; }
        if (!host_) {
            WNDCLASSW cls{}; cls.lpfnWndProc=Procedure; cls.hInstance=module_;
            cls.lpszClassName=L"TaskbarFollow.HoverPreview";
            RegisterClassW(&cls);
            host_=CreateWindowExW(WS_EX_NOACTIVATE|WS_EX_TOOLWINDOW|WS_EX_TRANSPARENT,
                cls.lpszClassName,L"",WS_POPUP,0,0,0,0,nullptr,nullptr,module_,nullptr);
            if (!host_) return false;
            const BOOL excluded=TRUE;
            DwmSetWindowAttribute(host_,DWMWA_EXCLUDED_FROM_PEEK,&excluded,sizeof(excluded));
        }
        RECT popupRect{}; GetWindowRect(popup,&popupRect);
        if (source_!=source) {
            Hide();
            if (FAILED(DwmRegisterThumbnail(host_,source,&thumbnail_))) return false;
            source_=source;
        }
        SIZE size{};
        if (FAILED(DwmQueryThumbnailSourceSize(thumbnail_,&size)) || size.cx<=0 || size.cy<=0) { Hide(); return false; }
        WINDOWPLACEMENT placement{sizeof(placement)}; GetWindowPlacement(source,&placement);
        const bool maximized=IsZoomed(source) || (IsIconic(source) && (placement.flags&WPF_RESTORETOMAXIMIZED));
        double scale=std::min(double(info.rcWork.right-info.rcWork.left)/size.cx,double(info.rcWork.bottom-info.rcWork.top)/size.cy);
        if (!maximized) scale=std::min(1.0,scale);
        const int width=std::max(1,static_cast<int>(std::lround(size.cx*scale)));
        const int height=std::max(1,static_cast<int>(std::lround(size.cy*scale)));
        RECT destination{info.rcWork.left+(info.rcWork.right-info.rcWork.left-width)/2,
            info.rcWork.top+(info.rcWork.bottom-info.rcWork.top-height)/2,0,0};
        destination.right=destination.left+width; destination.bottom=destination.top+height;
        if (Visible() && popup_==popup && EqualRect(&destination_,&destination) && EqualRect(&popupRect_,&popupRect)) return true;
        destination_=destination; popupRect_=popupRect; popup_=popup;
        SetWindowPos(host_,HWND_TOPMOST,destination.left,destination.top,width,height,SWP_NOACTIVATE|SWP_NOOWNERZORDER);
        // Leave a literal hole for the taskbar picker, even on shells where an
        // ordinary topmost window can overlap the popup's composition band.
        HRGN region=CreateRectRgn(0,0,width,height);
        HRGN hole=CreateRectRgn(popupRect.left-destination.left,popupRect.top-destination.top,
            popupRect.right-destination.left,popupRect.bottom-destination.top);
        CombineRgn(region,region,hole,RGN_DIFF); DeleteObject(hole);
        if (!SetWindowRgn(host_,region,FALSE)) DeleteObject(region);
        DWM_THUMBNAIL_PROPERTIES properties{};
        properties.dwFlags=DWM_TNP_RECTDESTINATION|DWM_TNP_VISIBLE|DWM_TNP_OPACITY|DWM_TNP_SOURCECLIENTAREAONLY;
        properties.rcDestination={0,0,width,height}; properties.fVisible=TRUE;
        properties.opacity=255; properties.fSourceClientAreaOnly=FALSE;
        if (FAILED(DwmUpdateThumbnailProperties(thumbnail_,&properties))) { Hide(); return false; }
        ShowWindow(host_,SW_SHOWNOACTIVATE);
        SetPropW(host_,L"TaskbarFollow.PeekSource",source);
        return true;
    }
};
