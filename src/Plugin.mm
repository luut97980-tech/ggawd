#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#include "mobile_menu.hpp"
#include "game_backend.hpp"
#include "ios_build_guard.hpp"
#include "app_metadata_apple.hpp"
#include "generated_font.hpp"
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <cstring>
#include <cstdio>
#include <memory>
#include "imgui_impl_metal.h"
#include <cfloat>
#include <cmath>
#include <limits>

@interface NSBundle (VTBundleSpoof)
-(NSString*)vt_bundleIdentifier;
-(id)vt_objectForInfoDictionaryKey:(NSString*)key;
-(NSDictionary<NSString*,id>*)vt_infoDictionary;
@end

@implementation NSBundle (VTBundleSpoof)
-(NSString*)vt_bundleIdentifier{
    if(self==NSBundle.mainBundle)return @"com.vng.playtogether";
    return [self vt_bundleIdentifier];
}
-(id)vt_objectForInfoDictionaryKey:(NSString*)key{
    if(self==NSBundle.mainBundle&&[key isKindOfClass:NSString.class]&&[key isEqualToString:@"CFBundleIdentifier"]){
        return @"com.vng.playtogether";
    }
    return [self vt_objectForInfoDictionaryKey:key];
}
-(NSDictionary<NSString*,id>*)vt_infoDictionary{
    NSDictionary<NSString*,id>*dict=[self vt_infoDictionary];
    if(self==NSBundle.mainBundle&&dict){
        id cur=dict[@"CFBundleIdentifier"];
        if(![cur isKindOfClass:NSString.class]||![(NSString*)cur isEqualToString:@"com.vng.playtogether"]){
            NSMutableDictionary<NSString*,id>*copy=[dict mutableCopy];
            copy[@"CFBundleIdentifier"]=@"com.vng.playtogether";
            return copy;
        }
    }
    return dict;
}
@end

static void VTSwizzleMethod(Class cls,SEL origSel,SEL swizSel){
    Method origMethod=class_getInstanceMethod(cls,origSel);
    Method swizMethod=class_getInstanceMethod(cls,swizSel);
    if(!origMethod||!swizMethod)return;
    if(class_addMethod(cls,origSel,method_getImplementation(swizMethod),method_getTypeEncoding(swizMethod))){
        class_replaceMethod(cls,swizSel,method_getImplementation(origMethod),method_getTypeEncoding(origMethod));
    }else{
        method_exchangeImplementations(origMethod,swizMethod);
    }
}

static void VTSpoofBundleIdentifier(){
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken,^{
        Class cls=NSBundle.class;
        VTSwizzleMethod(cls,@selector(bundleIdentifier),@selector(vt_bundleIdentifier));
        VTSwizzleMethod(cls,@selector(objectForInfoDictionaryKey:),@selector(vt_objectForInfoDictionaryKey:));
        VTSwizzleMethod(cls,@selector(infoDictionary),@selector(vt_infoDictionary));
        @try{
            CFBundleRef mainCF=CFBundleGetMainBundle();
            if(mainCF){
                CFDictionaryRef cfDict=CFBundleGetInfoDictionary(mainCF);
                if(cfDict){
                    NSDictionary*nsDict=(__bridge NSDictionary*)cfDict;
                    if([nsDict isKindOfClass:NSMutableDictionary.class]){
                        ((NSMutableDictionary*)nsDict)[@"CFBundleIdentifier"]=@"com.vng.playtogether";
                    }
                }
            }
        }@catch(id){}
    });
}

static void* VTUnityHandle=nullptr;
static std::string VTGuardMessage,VTGuardDetails;
static bool VTGuardMayRetry=true;
static bool VTCheckBuild(){
    VTGuardMayRetry=true;
    const auto metadata=vt::ios::readAppMetadata();
    const auto decision=vt::ios::chooseMetadata(metadata.disk,metadata.bundle);
    VTGuardDetails=vt::ios::metadataReport(metadata)+"\nMetadata source: "+decision.source;
    if(!decision.compatible){
        VTGuardMayRetry=decision.retryable;
        const auto& observed=metadata.disk.present?metadata.disk:metadata.bundle;
        VTGuardMessage=decision.retryable?"Waiting for app metadata":
            "App metadata mismatch: "+vt::ios::metadataLine("observed",observed);
        return false;
    }
    for(uint32_t i=0;i<_dyld_image_count();++i){
        const char*name=_dyld_get_image_name(i);if(!name||!strstr(name,"/UnityFramework.framework/UnityFramework"))continue;
        const auto*h=reinterpret_cast<const mach_header_64*>(_dyld_get_image_header(i));
        if(!h||h->magic!=MH_MAGIC_64||h->cputype!=CPU_TYPE_ARM64||h->ncmds>4096||h->sizeofcmds>1048576){VTGuardMayRetry=false;VTGuardMessage="Invalid UnityFramework Mach-O header";return false;}
        const auto*base=reinterpret_cast<const unsigned char*>(h);const unsigned char*cmd=base+sizeof(*h),*end=cmd+h->sizeofcmds;
        std::string uuid;uint64_t textStart=0,textEnd=0;
        for(uint32_t j=0;j<h->ncmds;++j){
            if(cmd+sizeof(load_command)>end){VTGuardMayRetry=false;VTGuardMessage="Invalid Mach-O command table";return false;}
            const auto*lc=reinterpret_cast<const load_command*>(cmd);if(lc->cmdsize<sizeof(*lc)||cmd+lc->cmdsize>end){VTGuardMayRetry=false;VTGuardMessage="Invalid Mach-O command";return false;}
            if(lc->cmd==LC_UUID&&lc->cmdsize>=sizeof(uuid_command)){auto*u=reinterpret_cast<const uuid_command*>(cmd);char hex[33];for(int k=0;k<16;k++)snprintf(hex+k*2,3,"%02x",u->uuid[k]);uuid=hex;}
            if(lc->cmd==LC_SEGMENT_64&&lc->cmdsize>=sizeof(segment_command_64)){auto*seg=reinterpret_cast<const segment_command_64*>(cmd);if(strncmp(seg->segname,"__TEXT",16)==0){textStart=seg->vmaddr;textEnd=textStart+seg->vmsize;}}
            cmd+=lc->cmdsize;
        }
        VTGuardDetails+="\nUnityFramework UUID: "+uuid+"\nExpected UUID: "+vt::ios::ExpectedFrameworkUUID;
        if(uuid!=vt::ios::ExpectedFrameworkUUID){VTGuardMayRetry=false;VTGuardMessage="UnityFramework UUID mismatch";return false;}
        for(const auto&g:vt::ios::MethodGuards){
            if(g.rva<textStart||g.rva>textEnd||g.bytes.size()>textEnd-g.rva||memcmp(base+g.rva,g.bytes.data(),g.bytes.size())!=0){
                char detail[80];snprintf(detail,sizeof(detail),"iOS method signature mismatch at RVA 0x%llx",static_cast<unsigned long long>(g.rva));
                VTGuardMayRetry=false;VTGuardMessage=detail;return false;
            }
        }
        if(!VTUnityHandle)VTUnityHandle=dlopen(name,RTLD_LAZY|RTLD_NOLOAD);
        if(!VTUnityHandle){VTGuardMessage="UnityFramework is not loaded";return false;}
        VTGuardMessage="Installed app metadata + UUID + iOS method signatures confirmed";return true;
    }
    VTGuardMessage="Waiting for UnityFramework (will retry)";return false;
}

@class VTMenuController;
@class VTPassthroughView;

@interface VTMetalView : MTKView
@property(nonatomic,weak) id touchOwner;
@end

// Plain NSObject controller (not a UIViewController) so its overlay view is a
// pure UIView with no _viewDelegate. This prevents UIViewControllerHierarchyInconsistency
// without creating any extra UIWindow that would interfere with PassSDK/login flows.
@interface VTMenuController : NSObject<MTKViewDelegate> {
    ImGuiContext* _context;
    vt::ios::Model _model;
    vt::ios::Actions _actions;
    std::unique_ptr<vt::ios::GameBackend> _backend;
    UITouch* _primaryTouch;
    CGPoint _touchStart,_touchPrevious;
    BOOL _panning;
    CFTimeInterval _lastFrame,_nextBuildCheck,_resumeAfter;
    CGSize _lastLayoutSize;
}
@property(nonatomic,strong) VTPassthroughView* view;
@property(nonatomic,strong) VTMetalView* metalView;
@property(nonatomic,strong) id<MTLDevice> device;
@property(nonatomic,strong) id<MTLCommandQueue> commandQueue;
-(instancetype)initWithFrame:(CGRect)frame;
-(void)beginTouches:(NSSet<UITouch*>*)touches;
-(void)moveTouches:(NSSet<UITouch*>*)touches;
-(void)endTouches:(NSSet<UITouch*>*)touches cancelled:(BOOL)cancelled;
-(void)setRenderingActive:(BOOL)active;
-(BOOL)acceptsPoint:(CGPoint)point;
-(void)tryStartBackend:(CFTimeInterval)now;
-(void)handleLayoutChange:(CGSize)size;
@end

@interface VTPassthroughView:UIView
@property(nonatomic,weak) VTMenuController*menuController;
@end
@implementation VTPassthroughView
-(UIView*)hitTest:(CGPoint)point withEvent:(UIEvent*)event{
    if(self.hidden||self.alpha<.01||!self.userInteractionEnabled||![self pointInside:point withEvent:event]||!self.menuController.metalView)return nil;
    CGPoint local=[self.menuController.metalView convertPoint:point fromView:self];
    if(![self.menuController acceptsPoint:local])return nil;
    return [super hitTest:point withEvent:event];
}
-(void)layoutSubviews{
    [super layoutSubviews];
    [self.menuController handleLayoutChange:self.bounds.size];
}
@end

@implementation VTMetalView
-(void)touchesBegan:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event{[(VTMenuController*)self.touchOwner beginTouches:touches];}
-(void)touchesMoved:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event{[(VTMenuController*)self.touchOwner moveTouches:touches];}
-(void)touchesEnded:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event{[(VTMenuController*)self.touchOwner endTouches:touches cancelled:NO];}
-(void)touchesCancelled:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event{[(VTMenuController*)self.touchOwner endTouches:touches cancelled:YES];}
@end

@implementation VTMenuController
-(instancetype)initWithFrame:(CGRect)frame{
    self=[super init];
    if(!self)return nil;
    VTPassthroughView*root=[[VTPassthroughView alloc]initWithFrame:frame];
    root.menuController=self;
    root.backgroundColor=UIColor.clearColor;
    root.opaque=NO;
    root.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
    self.view=root;
    [self setupView];
    return self;
}
-(NSURL*)settingsURL{
    NSURL*base=[[NSFileManager defaultManager]URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL*folder=[base URLByAppendingPathComponent:@"VTMenu" isDirectory:YES];
    [[NSFileManager defaultManager]createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:nil];
    return [folder URLByAppendingPathComponent:@"config.json"];
}
-(void)restoreSettings{
    NSData*data=[NSData dataWithContentsOfURL:[self settingsURL]];
    id parsed=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;
    NSDictionary*saved=[parsed isKindOfClass:NSDictionary.class]?parsed:@{};
    if([saved[@"scale"] isKindOfClass:NSNumber.class])_model.scale=[saved[@"scale"] floatValue];
    if([saved[@"opacity"] isKindOfClass:NSNumber.class])_model.opacity=[saved[@"opacity"] floatValue];
    if([saved[@"jump_interval_ms"] isKindOfClass:NSNumber.class])_model.jumpIntervalMs=[saved[@"jump_interval_ms"]doubleValue];
    else {NSArray*old=saved[@"numbers"];if([old isKindOfClass:NSArray.class]&&old.count==4&&[old[3] isKindOfClass:NSNumber.class])_model.jumpIntervalMs=[old[3]doubleValue];}
    vt::ios::sanitize(_model);_model.enabled.fill(false);_model.visible=false;
}
-(void)saveSettings{
    vt::ios::sanitize(_model);
    NSDictionary*settings=@{@"schema":@3,@"scale":@(_model.scale),@"opacity":@(_model.opacity),@"jump_interval_ms":@(_model.jumpIntervalMs)};
    NSData*data=[NSJSONSerialization dataWithJSONObject:settings options:NSJSONWritingPrettyPrinted error:nil];
    NSError*error=nil;
    if(!data||![data writeToURL:[self settingsURL] options:NSDataWritingAtomic error:&error])_model.status="Không ghi được config.json";
}
-(BOOL)acceptsPoint:(CGPoint)p{
    return vt::ios::acceptsPoint(_model,{float(p.x),float(p.y)});
}
-(void)setupView{
    [self restoreSettings];self.device=MTLCreateSystemDefaultDevice();
    if(!self.device){UILabel*label=[[UILabel alloc]initWithFrame:self.view.bounds];label.text=@"Thiết bị không khởi tạo được Metal.";label.textColor=UIColor.whiteColor;label.numberOfLines=0;label.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;[self.view addSubview:label];return;}
    self.commandQueue=[self.device newCommandQueue];
    self.metalView=[[VTMetalView alloc]initWithFrame:self.view.bounds device:self.device];self.metalView.delegate=self;self.metalView.touchOwner=self;
    self.metalView.multipleTouchEnabled=YES;self.metalView.preferredFramesPerSecond=60;
    self.metalView.colorPixelFormat=MTLPixelFormatBGRA8Unorm;self.metalView.opaque=NO;self.metalView.layer.opaque=NO;self.metalView.backgroundColor=UIColor.clearColor;self.metalView.clearColor=MTLClearColorMake(0,0,0,0);
    self.metalView.translatesAutoresizingMaskIntoConstraints=NO;[self.view addSubview:self.metalView];
    UIView*g=self.view;
    [NSLayoutConstraint activateConstraints:@[[self.metalView.leadingAnchor constraintEqualToAnchor:g.leadingAnchor],[self.metalView.trailingAnchor constraintEqualToAnchor:g.trailingAnchor],[self.metalView.topAnchor constraintEqualToAnchor:g.topAnchor],[self.metalView.bottomAnchor constraintEqualToAnchor:g.bottomAnchor]]];
    IMGUI_CHECKVERSION();_context=ImGui::CreateContext();ImGuiIO&io=ImGui::GetIO();io.IniFilename=nullptr;io.LogFilename=nullptr;io.ConfigFlags|=ImGuiConfigFlags_NoMouseCursorChange;
    CGFloat scale=UIScreen.mainScreen.scale;ImFontConfig cfg;cfg.OversampleH=2;cfg.OversampleV=1;cfg.FontDataOwnedByAtlas=false;
    io.Fonts->AddFontFromMemoryTTF(const_cast<unsigned char*>(vt::ios::FontBytes),int(sizeof(vt::ios::FontBytes)),16.f*scale,&cfg,io.Fonts->GetGlyphRangesVietnamese());
    if(io.Fonts->Fonts.empty())io.Fonts->AddFontDefault();
    // Rasterize at Retina scale, then return glyph geometry to UIKit points.
    for(ImFont*f:io.Fonts->Fonts)f->Scale=1.f/float(scale);
    vt::ios::style();ImGui_ImplMetal_Init(self.device);
    _model.available.fill(false);
    for(int id:{vt::Esp,vt::SpamJump})_model.available[id]=true;
    _resumeAfter=0;
    _nextBuildCheck=0;
    _model.status="Mở menu sau khi đăng nhập để kết nối";
    __weak VTMenuController*weakSelf=self;
    _actions.save=[weakSelf]{VTMenuController*strong=weakSelf;if(strong)[strong saveSettings];};
    _actions.stop=[weakSelf]{VTMenuController*strong=weakSelf;if(strong&&strong->_backend)strong->_backend->stop(strong->_model);};
    _actions.number=[weakSelf](int,double){VTMenuController*strong=weakSelf;if(strong)[strong saveSettings];};
    _actions.toggle=[weakSelf](int id){VTMenuController*strong=weakSelf;if(strong&&strong->_backend)strong->_backend->toggle(strong->_model,id);};
    _actions.diagnostic=[weakSelf]{VTMenuController*strong=weakSelf;if(strong){
        if(!strong->_backend){strong->_nextBuildCheck=0;[strong tryStartBackend:CACurrentMediaTime()];}
        const auto metadata=vt::ios::readAppMetadata();
        UIView*host=strong.view.superview;const CGSize size=host.bounds.size;const CGAffineTransform t=host.transform;const UIEdgeInsets insets=host.safeAreaInsets;
        const char*hostClass=NSStringFromClass(host.class).UTF8String;char hostInfo[320];
        snprintf(hostInfo,sizeof(hostInfo),"UI container: %s; bounds=%.0fx%.0f; inset=%.0f,%.0f,%.0f,%.0f; orientation=%ld; transform=%.2f,%.2f,%.2f,%.2f",hostClass?hostClass:"none",double(size.width),double(size.height),double(insets.top),double(insets.left),double(insets.bottom),double(insets.right),long(host.window.windowScene.interfaceOrientation),double(t.a),double(t.b),double(t.c),double(t.d));
        strong->_model.diagnostic="PTG iOS R5.3 | target VNG 2.32.0 (227628) | arm64\n"+VTGuardMessage+"\n"+VTGuardDetails+
            "\n"+std::string(hostInfo)+"\nCurrent metadata:\n"+vt::ios::metadataReport(metadata)+"\nStatus: "+strong->_model.status+"\n"+
            (strong->_backend?strong->_backend->diagnostic():"Backend unavailable")+
            "\nWeb key client and capture hiding are not implemented on iOS.";
        UIPasteboard.generalPasteboard.string=[NSString stringWithUTF8String:strong->_model.diagnostic.c_str()];
        strong->_model.toast="Đã sao chép chẩn đoán";strong->_model.toastUntil=strong->_model.time+1.;
    }};
}
-(void)tryStartBackend:(CFTimeInterval)now{
    if(_backend||now<_nextBuildCheck)return;
    _model.connected=false;_model.controlsAllowed=false;
    if(!VTCheckBuild()){
        _model.status=VTGuardMessage;
        _nextBuildCheck=VTGuardMayRetry?now+1.:std::numeric_limits<double>::infinity();
        return;
    }
    try{
        _backend=std::make_unique<vt::ios::GameBackend>([](const char*n){return dlsym(VTUnityHandle,n);});
        _model.connected=true;_model.controlsAllowed=true;
        _model.status="Đã xác minh bản game; bật ESP hoặc Spam nhảy";
    }catch(const std::exception&e){
        _model.status=e.what();_nextBuildCheck=std::numeric_limits<double>::infinity();
    }
}
-(void)handleLayoutChange:(CGSize)size{
    if(size.width<=0||size.height<=0)return;
    if(!CGSizeEqualToSize(size,_lastLayoutSize)){
        [self cancelMouse];_primaryTouch=nil;_panning=NO;_model.scrollDelta=0;_model.suppressActions=true;
        _model.windowMin=_model.windowMax={};_lastLayoutSize=size;
        if(_backend)_backend->suspend(CACurrentMediaTime());
    }
}
-(void)cancelMouse{
    if(!_context)return;ImGui::SetCurrentContext(_context);auto&io=ImGui::GetIO();io.AddMouseSourceEvent(ImGuiMouseSource_TouchScreen);io.AddMousePosEvent(-FLT_MAX,-FLT_MAX);io.AddMouseButtonEvent(0,false);
}
-(void)beginTouches:(NSSet<UITouch*>*)touches{
    if(!_context||_primaryTouch)return;_primaryTouch=touches.anyObject;
    _touchStart=_touchPrevious=[_primaryTouch locationInView:self.metalView];_panning=NO;_model.suppressActions=false;
    ImGui::SetCurrentContext(_context);auto&io=ImGui::GetIO();io.AddMouseSourceEvent(ImGuiMouseSource_TouchScreen);io.AddMousePosEvent(_touchStart.x,_touchStart.y);io.AddMouseButtonEvent(0,true);
}
-(void)moveTouches:(NSSet<UITouch*>*)touches{
    if(!_context||!_primaryTouch||![touches containsObject:_primaryTouch])return;
    CGPoint p=[_primaryTouch locationInView:self.metalView];CGFloat dx=p.x-_touchStart.x,dy=p.y-_touchStart.y;
    const BOOL inContent=_touchStart.x>=_model.contentMin.x&&_touchStart.x<_model.contentMax.x&&_touchStart.y>=_model.contentMin.y&&_touchStart.y<_model.contentMax.y;
    if(!_panning&&_model.visible&&inContent&&!_model.sliderActive&&fabs(dy)>14&&fabs(dy)>fabs(dx)*1.5){_panning=YES;_model.suppressActions=true;[self cancelMouse];}
    if(_panning){_model.scrollDelta+=p.y-_touchPrevious.y;}
    else{ImGui::SetCurrentContext(_context);ImGui::GetIO().AddMousePosEvent(p.x,p.y);}
    _touchPrevious=p;
}
-(void)endTouches:(NSSet<UITouch*>*)touches cancelled:(BOOL)cancelled{
    if(!_context||!_primaryTouch||![touches containsObject:_primaryTouch])return;
    ImGui::SetCurrentContext(_context);
    if(cancelled||_panning){_model.suppressActions=true;[self cancelMouse];}
    else{CGPoint p=[_primaryTouch locationInView:self.metalView];auto&io=ImGui::GetIO();io.AddMousePosEvent(p.x,p.y);io.AddMouseButtonEvent(0,false);}
    _primaryTouch=nil;_panning=NO;
}
-(void)setRenderingActive:(BOOL)active{
    [self cancelMouse];_primaryTouch=nil;_panning=NO;_model.scrollDelta=0;_model.suppressActions=true;
    if(!active){if(_backend)_backend->stop(_model);_model.visible=false;_model.enabled.fill(false);[self saveSettings];_resumeAfter=0;}
    else{
        _resumeAfter=CACurrentMediaTime()+1.;
        if(_backend)_backend->suspend(CACurrentMediaTime());
    }
    self.metalView.paused=!active;_lastFrame=0;
}
-(void)drawInMTKView:(MTKView*)view{
    if(!_context||view.paused||view.bounds.size.width<=0||view.bounds.size.height<=0)return;
    ImGui::SetCurrentContext(_context);auto&io=ImGui::GetIO();io.DisplaySize={float(view.bounds.size.width),float(view.bounds.size.height)};
    io.DisplayFramebufferScale={float(view.drawableSize.width/view.bounds.size.width),float(view.drawableSize.height/view.bounds.size.height)};
    CFTimeInterval now=CACurrentMediaTime();io.DeltaTime=_lastFrame?float(fmin(.1,fmax(.001,now-_lastFrame))):1.f/60;_lastFrame=now;
    const CGSize bounds=view.bounds.size;
    if(!CGSizeEqualToSize(bounds,_lastLayoutSize)){
        [self cancelMouse];_primaryTouch=nil;_panning=NO;_model.scrollDelta=0;_model.suppressActions=true;
        _model.windowMin=_model.windowMax={};_lastLayoutSize=bounds;
        if(_backend)_backend->suspend(now);
    }
    id<CAMetalDrawable> drawable=view.currentDrawable;MTLRenderPassDescriptor*pass=view.currentRenderPassDescriptor;if(!drawable||!pass)return;
    id<MTLCommandBuffer>command=[self.commandQueue commandBuffer];if(!command)return;
    _model.time=now;_model.insetMin={float(view.safeAreaInsets.left),float(view.safeAreaInsets.top)};_model.insetMax={float(view.safeAreaInsets.right),float(view.safeAreaInsets.bottom)};
    // Only connect backend when user opens the menu or enables a feature,
    // staying completely passive during app startup and account login.
    if(_model.visible||vt::ios::runtimeRequested(_model)){
        [self tryStartBackend:now];
    }
    if(now>=_resumeAfter&&_backend)_backend->tick(_model,now);
    bool busy=_model.visible||vt::ios::runtimeRequested(_model);view.preferredFramesPerSecond=busy?60:15;
    ImGui_ImplMetal_NewFrame(pass);ImGui::NewFrame();
    if(_backend&&_model.enabled[vt::Esp]){
        auto*d=ImGui::GetBackgroundDrawList();const float w=io.DisplaySize.x,h=io.DisplaySize.y;
        for(const auto&p:_backend->esp()){float x=p.x*w,bottom=p.y*h,top=p.headY*h,height=fabsf(bottom-top);if(height<4||height>h*2)continue;
            float left=x-height*.2f,right=x+height*.2f;ImU32 col=IM_COL32(183,174,255,220);
            d->AddRect({left,top},{right,bottom},col,2,0,1.5f);char label[100];snprintf(label,sizeof(label),"%s | %.0f m",p.label.c_str(),p.distance);d->AddText({left,top-18},col,label);
        }
    }
    vt::ios::draw(_model,_actions);ImGui::Render();
    id<MTLRenderCommandEncoder>encoder=[command renderCommandEncoderWithDescriptor:pass];if(!encoder)return;
    ImGui_ImplMetal_RenderDrawData(ImGui::GetDrawData(),command,encoder);[encoder endEncoding];[command presentDrawable:drawable];[command commit];
}
-(void)mtkView:(MTKView*)view drawableSizeWillChange:(CGSize)size{}
-(void)dealloc{
    if(_backend){_backend->stop(_model);_backend.reset();}
    _metalView.delegate=nil;_metalView.touchOwner=nil;
    if(_context){ImGui::SetCurrentContext(_context);ImGui_ImplMetal_Shutdown();ImGui::DestroyContext(_context);_context=nullptr;}
}
@end

static VTMenuController* VTController;
static __weak UIView* VTHostView;
static __weak UIWindowScene* VTHostScene;
static __weak UIWindow* VTHostWindow;
static NSTimer* VTHostTimer;

static UIView* VTFindGameView(UIView*view,int depth){
    if(!view||depth>24||view.hidden||view.alpha<.01||!view.window||[view isKindOfClass:VTPassthroughView.class])return nil;
    Class unity=NSClassFromString(@"UnityView"),rendering=NSClassFromString(@"UnityRenderingView");
    const bool unityView=unity&&[view isKindOfClass:unity];
    if((rendering&&[view isKindOfClass:rendering])||(unityView&&[view.layer isKindOfClass:CAMetalLayer.class]))return view;
    for(UIView*child in view.subviews){UIView*found=VTFindGameView(child,depth+1);if(found)return found;}
    if([view.layer isKindOfClass:CAMetalLayer.class]||unityView)return view;
    return nil;
}

static void VTDetach(){
    if(!VTController)return;
    [VTController setRenderingActive:NO];
    [VTController.view removeFromSuperview];
    VTController=nil;VTHostView=nil;VTHostScene=nil;VTHostWindow=nil;
}

static void VTAttach(){
    if(!NSThread.isMainThread){dispatch_async(dispatch_get_main_queue(),^{VTAttach();});return;}
    if(UIApplication.sharedApplication.applicationState!=UIApplicationStateActive)return;
    UIWindow*game=nil;UIView*unity=nil;
    for(UIScene*scene in UIApplication.sharedApplication.connectedScenes){
        if(![scene isKindOfClass:UIWindowScene.class]||scene.activationState!=UISceneActivationStateForegroundActive)continue;
        for(UIWindow*window in ((UIWindowScene*)scene).windows){
            if(window.hidden||window.alpha<.01||window.windowLevel!=UIWindowLevelNormal||![window.rootViewController isViewLoaded])continue;
            UIView*found=VTFindGameView(window.rootViewController.view,0);
            if(!found)continue;
            if(!game||[window isKeyWindow]){game=window;unity=found;}
            if([window isKeyWindow])break;
        }
        if(game&&[game isKeyWindow])break;
    }
    if(!game||!unity)return;
    UIViewController*parent=game.rootViewController;
    if(!parent||![parent isViewLoaded])return;
    // Do not disturb the hierarchy while any login sheet/popup (PassSDK, Facebook,
    // Google, Safari/ASWebAuthenticationSession) is presented or another window is key.
    if(parent.presentedViewController!=nil||![game isKeyWindow])return;
    UIView*container=parent.view;
    if(!container)return;
    if(!CGAffineTransformIsIdentity(container.transform))container=game;
    if(container!=game&&container.window!=game)return;
    const CGSize size=container.bounds.size;
    if(size.width<=0||size.height<=0)return;
    if(VTController&&VTController.view.superview&&VTHostView==container&&VTHostWindow==game&&!container.hidden&&container.alpha>=.01){
        if(!CGRectEqualToRect(VTController.view.frame,container.bounds))VTController.view.frame=container.bounds;
        if(container.subviews.lastObject!=VTController.view)[container bringSubviewToFront:VTController.view];
        if(VTController.view.hidden||VTController.metalView.paused){VTController.view.hidden=NO;[VTController setRenderingActive:YES];}
        return;
    }
    VTDetach();
    VTController=[[VTMenuController alloc]initWithFrame:container.bounds];
    VTHostView=container;VTHostScene=game.windowScene;VTHostWindow=game;
    [container addSubview:VTController.view];
}

extern "C" __attribute__((visibility("default"))) void VTMenuStart(){dispatch_async(dispatch_get_main_queue(),^{VTAttach();});}
__attribute__((constructor)) static void VTBootstrap(){
    VTSpoofBundleIdentifier();
    dispatch_async(dispatch_get_main_queue(),^{
        NSNotificationCenter*c=NSNotificationCenter.defaultCenter;
        [c addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification*n){VTAttach();}];
        [c addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification*n){[VTController setRenderingActive:NO];if(VTController&&VTController.view)VTController.view.hidden=YES;}];
        [c addObserverForName:UISceneDidDisconnectNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification*n){if(n.object==VTHostScene)VTDetach();}];
        VTHostTimer=[NSTimer scheduledTimerWithTimeInterval:.5 repeats:YES block:^(NSTimer*t){VTAttach();}];
        VTAttach();
    });
}
