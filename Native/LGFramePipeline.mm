#import "LGFramePipeline.h"
#include <opencv2/core.hpp>
#include <opencv2/imgproc.hpp>
#include <opencv2/calib3d.hpp>
#include <algorithm>
#include <array>
#include <cmath>
#include <stdexcept>
#include <vector>
#include <chrono>

using namespace cv;
using std::vector;
namespace {
using Points = std::array<Point2f,68>;
const std::array<Point3f,13> anchors = {{
    {0.0583285689f,-7.6068878174f,-15.6978569031f}, {-0.1037741378f,8.6476440430f,-22.1310577393f},
    {-0.2447226197f,23.3746013641f,-31.4599514008f}, {-0.3765539825f,35.0937423706f,-36.4029617309f},
    {-12.3622055054f,46.7120895386f,-14.9832811356f}, {-7.1424574852f,49.0878067017f,-18.2947559357f},
    {-0.2038182765f,50.2790718079f,-19.5088043213f}, {6.8097014427f,49.1204795837f,-18.3510112762f},
    {12.0658283234f,46.7335357666f,-15.0244798660f}, {-46.2558021545f,-1.6484832764f,2.8722748756f},
    {-19.0150337219f,1.5302906036f,-3.1016001701f}, {19.1684207916f,1.4967899323f,-2.8367133141f},
    {46.1024169922f,-1.3785972595f,3.0660386086f}
}};
const int poseIndices[] = {27,28,29,30,31,32,33,34,35,36,39,42,45};
const int eyeIndices[] = {37,38,40,41,43,44,46,47};

struct Letterbox { Mat image; Vec4f transform; };
Letterbox letterbox(const Mat &image, int width, int height) {
    double ratio=std::min(double(width)/image.cols,double(height)/image.rows);
    int rw=std::clamp(int(image.cols*ratio+0.5),1,width), rh=std::clamp(int(image.rows*ratio+0.5),1,height);
    int x=(width-rw)/2,y=(height-rh)/2;
    float sx=float(rw)/image.cols,sy=float(rh)/image.rows;
    Mat result=Mat::zeros(height,width,CV_8UC3);
    resize(image,result(cv::Rect(x,y,rw,rh)),cv::Size(rw,rh),0,0,std::max(sx,sy)>1?INTER_LANCZOS4:INTER_AREA);
    return {result,{sx,x+(sx-1)/2,sy,y+(sy-1)/2}};
}
vector<float> nchw(const Mat &image, bool rgb=false) {
    vector<float> result(3*image.total());
    for(int y=0;y<image.rows;y++) for(int x=0;x<image.cols;x++) for(int c=0;c<3;c++)
        result[c*image.total()+y*image.cols+x]=image.at<Vec3b>(y,x)[rgb?2-c:c]*(1.0f/255.0f);
    return result;
}
cv::Rect square(const Rect2f &r,float expansion) {
    Point2f center(r.x+r.width*.5f,r.y+r.height*.5f);
    float radius=std::max(r.width*.5f*(1+expansion),r.height*.5f*(1+expansion));
    // Reject unbounded finite model values before float-to-int conversion or
    // allocation. Ordinary model geometry and reference outputs are unchanged.
    if(!std::isfinite(radius)||!std::isfinite(center.x)||!std::isfinite(center.y)||radius<0||radius>4096||
       std::abs(center.x)>1e6f||std::abs(center.y)>1e6f)return cv::Rect();
    int side=int(std::round(radius+radius));
    return cv::Rect(int(std::round(center.x-side*.5f)),int(std::round(center.y-side*.5f)),side,side);
}
struct OneEuro {
    bool initialized=false;
    Points previous{},raw{},derivative{};
    void filter(Points &points) {
        if(!initialized) {previous=raw=points;derivative={};initialized=true;}
        constexpr float rate=float(30/(2*CV_PI));
        const float da=1/(rate+1);
        for(size_t i=0;i<68;i++) for(int axis=0;axis<2;axis++) {
            float &v=axis?points[i].y:points[i].x;
            float &r=axis?raw[i].y:raw[i].x, &p=axis?previous[i].y:previous[i].x;
            float &d=axis?derivative[i].y:derivative[i].x;
            d+=da*((v-r)*30-d);r=v;
            float cutoff=5+std::abs(d);p+=cutoff/(rate+cutoff)*(v-p);v=p;
        }
    }
};
struct BoxState {
    bool hasPrevious=false;
    Rect2f previous;
    std::array<float,8> x{},p{},q{{1e-5f,1e-5f,1e-5f,1e-5f,5,5,5,5}},r{{2.5e-6f,2.5e-6f,.0025f,.0025f,.01f,.01f,.01f,.01f}};
    std::array<bool,8> first{};
    BoxState(){resetFilters();}
    void resetFilters(){x.fill(0);p.fill(1);first.fill(true);}
    float filter(int i,float value){
        float old=first[i]?value:x[i];first[i]=false;
        float prediction=p[i]+q[i],gain=prediction/(prediction+r[i]);
        x[i]=(value-old)*gain+old;p[i]=(1-gain)*prediction;return x[i];
    }
    Rect2f smooth(Rect2f box){
        Point2f center(box.x+box.width*.5f,box.y+box.height*.5f);
        bool restart=!hasPrevious || center.x<previous.x || center.y<previous.y ||
            center.x>previous.x+previous.width || center.y>previous.y+previous.height ||
            std::abs(previous.width-box.width)/box.width>=.2f || std::abs(previous.height-box.height)/box.height>=.2f;
        if(restart)resetFilters();
        else {
            Point2f old(previous.x+previous.width*.5f,previous.y+previous.height*.5f),delta=center-old;
            center=old+Point2f(std::copysign(filter(4,std::abs(delta.x)),delta.x),std::copysign(filter(5,std::abs(delta.y)),delta.y));
            box.width=previous.width*filter(6,box.width/previous.width);
            box.height=previous.height*filter(7,box.height/previous.height);
        }
        center={filter(0,center.x),filter(1,center.y)};
        float w=filter(2,box.width),h=filter(3,box.height);
        previous={center.x-w*.5f,center.y-h*.5f,w,h};hasPrevious=true;return previous;
    }
};
struct FeatureState {
    double meanAspect=.3,pitchAlpha=0,yawAlpha=0;
    int frames=0;bool blink=false;
    static double transition(double angle,double start,double end){
        double t=std::clamp((std::abs(angle)-start*CV_PI/180)/((end-start)*CV_PI/180),0.,1.);
        return t*t*t*(10+t*(-15+6*t));
    }
    static double advance(double old,double desired){return old+std::clamp(desired-old,-.1,.1);}
    Vec2f target(const vector<float> &labels,const Points &points,Vec2f head){
        double aspect=1e10;
        for(int base:{36,42}){
            double width=norm(points[base]-points[base+3]);
            if(width<1e-5)throw std::runtime_error("degenerate_eyelids");
            aspect=std::min(aspect,(norm(points[base+1]-points[base+5])+norm(points[base+2]-points[base+4]))/(2*width));
        }
        frames++;meanAspect+=.02*(aspect-meanAspect);
        bool previousBlink=blink;blink=frames>5 && !(aspect>.65*meanAspect && aspect>=.15);
        if(previousBlink&&!blink)frames=0;
        double pitch=labels[10],yaw=labels[11];
        yawAlpha=advance(yawAlpha,1-(1-transition(yaw,20,30))*(1-transition(head[1],25,30)));
        pitchAlpha=blink?1:advance(pitchAlpha,1-(1-transition(pitch,20,30))*(1-transition(head[0],15,25)));
        return {float(pitchAlpha*pitch),float(yawAlpha*yaw)};
    }
};
struct Geometry { Matx33f homography; Vec2f head; float depth; };
Geometry geometry(const Points &points,int width,int height){
    double f=(width/2.)/std::tan(40*CV_PI/180);
    Matx33f camera(float(f),0,width/2.f,0,float(f),height/2.f,0,0,1);
    vector<Point3d> object;vector<Point2d> image;
    for(int i=0;i<13;i++){object.emplace_back(anchors[i]);image.emplace_back(points[poseIndices[i]]);}
    Mat observation(13,2,CV_64F);
    Point2d mean;for(auto p:image)mean+=p;mean*=1./13;
    for(int i=0;i<13;i++){observation.at<double>(i,0)=image[i].x-mean.x;observation.at<double>(i,1)=image[i].y-mean.y;}
    Mat singular;SVD::compute(observation,singular);
    if(singular.at<double>(1)<1e-3)throw std::runtime_error("degenerate_face_geometry");
    Mat camera64;Mat(camera).convertTo(camera64,CV_64F);
    Mat rvec,tvec;
    if(!solvePnP(object,image,camera64,noArray(),rvec,tvec,false,SOLVEPNP_SQPNP))throw std::runtime_error("invalid_face_geometry");
    solvePnPRefineLM(object,image,camera64,noArray(),rvec,tvec,TermCriteria(TermCriteria::COUNT|TermCriteria::EPS,20,1e-8));
    Mat matrix;Rodrigues(rvec,matrix);
    Matx33d rd=matrix;Vec3d td=tvec;
    for(auto p:object)if((rd*Vec3d(p)+td)[2]<=1e-5)throw std::runtime_error("pose_behind_camera");
    // Reconstruct from the same float32 Euler boundary as Python.
    float ax=float(std::atan2(-rd(1,2),rd(2,2))),ay=float(std::asin(std::clamp(rd(0,2),-1.,1.))),az=float(std::atan2(-rd(0,1),rd(0,0)));
    float sx=std::sin(ax),cx=std::cos(ax),sy=std::sin(ay),cy=std::cos(ay),sz=std::sin(az),cz=std::cos(az);
    Matx33f rotation=Matx33f(1,0,0,0,cx,-sx,0,sx,cx)*Matx33f(cy,0,sy,0,1,0,-sy,0,cy)*Matx33f(cz,-sz,0,sz,cz,0,0,0,1);
    Vec3f t{float(td[0]),float(td[1]),float(td[2])};
    Vec3f origin=(rotation*Vec3f(anchors[10])+t+rotation*Vec3f(anchors[11])+t)*.5f+Vec3f(0,-.5f,0);
    float distance=float(norm(origin));
    if(distance<1e-5f||origin[2]<=0)throw std::runtime_error("invalid_gaze_origin");
    Vec3f forward=origin/distance,down=forward.cross(Vec3f(rotation(0,0),rotation(1,0),rotation(2,0)));
    if(norm(down)<1e-5)throw std::runtime_error("degenerate_head_orientation");
    down/=float(norm(down));Vec3f right=down.cross(forward);right/=float(norm(right));
    Matx33f normal(right[0],right[1],right[2],down[0],down[1],down[2],forward[0],forward[1],forward[2]);
    Vec3f direction=normal*Vec3f(rotation(0,2),rotation(1,2),rotation(2,2));
    Matx33f homography=Matx33f(1300,0,128,0,1300,32,0,0,1)*Matx33f(1,0,0,0,1,0,0,0,600/distance)*normal*camera.inv();
    return {homography,{std::asin(std::clamp(direction[1],-1.f,1.f)),std::atan2(direction[0],direction[2])},t[2]};
}
Mat warpPatch(const Mat &frame,const Matx33f &h){
    Matx33d hd(h);Matx33d inverse=hd.inv();Mat patch=Mat::zeros(64,256,CV_8UC3);
    for(int y=0;y<64;y++)for(int x=0;x<256;x++){
        Vec3d q=inverse*Vec3d(x,y,1);double px=q[0]/q[2],py=q[1]/q[2];
        if(!(px>=0&&px<=frame.cols-1&&py>=0&&py<=frame.rows-1))continue;
        int ix=int(px),iy=int(py),jx=std::min(ix+1,frame.cols-1),jy=std::min(iy+1,frame.rows-1);
        double dx=px-ix,dy=py-iy;
        for(int c=0;c<3;c++){
            double v=frame.at<Vec3b>(iy,ix)[c]*(1-dx)*(1-dy)+frame.at<Vec3b>(iy,jx)[c]*dx*(1-dy)+frame.at<Vec3b>(jy,ix)[c]*(1-dx)*dy+frame.at<Vec3b>(jy,jx)[c]*dx*dy;
            patch.at<Vec3b>(y,x)[c]=uchar(std::clamp(std::floor(v+.5),0.,255.));
        }
    }
    return patch;
}
Mat eyeMask(const std::array<Point2f,12> &points){
    vector<vector<cv::Point>> polygons(2);
    for(int i=0;i<12;i++){
        auto p=points[i];if(!std::isfinite(p.x)||!std::isfinite(p.y)||p.x<0||p.y<0||p.x>=256||p.y>=64)throw std::runtime_error("eye_contour_outside_patch");
        polygons[i/6].push_back({int(std::nearbyint(p.x*256)),int(std::nearbyint(p.y*256))});
    }
    Mat mask=Mat::zeros(64,256,CV_8U);fillPoly(mask,polygons,Scalar(255),LINE_8,8);return mask;
}
void restore(Mat &frame,const Mat &patch,const vector<float>&decoded,const vector<float>&lids,const Points &points,const Matx33f&h){
    std::array<Point2f,12> original,redirected;
    for(int i=0;i<12;i++){
        Vec3f p=h*Vec3f(points[36+i].x,points[36+i].y,1);
        if(std::abs(p[2])<1e-7)throw std::runtime_error("point_at_infinity");
        original[i]={p[0]/p[2],p[1]/p[2]};redirected[i]={(lids[i]+.5f)*256,(lids[i+12]+.5f)*64};
    }
    // Three radius-2 dilations plus a radius-7 blur need 13 pixels of
    // zero padding. Keep 16 on every edge instead of processing 4x the patch.
    constexpr int maskBorder=16;
    Mat mask=eyeMask(original)|eyeMask(redirected),padded=Mat::zeros(64+2*maskBorder,256+2*maskBorder,CV_8U);
    mask.copyTo(padded(cv::Rect(maskBorder,maskBorder,256,64)));
    Mat kernel=(Mat_<uchar>(5,5)<<0,0,1,0,0,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,0,0,1,0,0);
    dilate(padded,padded,kernel,cv::Point(-1,-1),3,BORDER_REPLICATE);
    Mat blurred;padded.convertTo(blurred,CV_64F);GaussianBlur(blurred,blurred,cv::Size(15,15),3.4,0,BORDER_REPLICATE);
    Mat alpha(64,256,CV_8U);for(int y=0;y<64;y++)for(int x=0;x<256;x++)alpha.at<uchar>(y,x)=uchar(std::clamp(blurred.at<double>(y+maskBorder,x+maskBorder)+64*DBL_EPSILON*255,0.,255.));
    Mat corrected(64,256,CV_8UC3);for(int y=0;y<64;y++)for(int x=0;x<256;x++)for(int c=0;c<3;c++)corrected.at<Vec3b>(y,x)[c]=uchar(std::clamp(decoded[(2-c)*64*256+y*256+x]*255,0.f,255.f)+.5f);
    Mat sharp;Mat sharpenKernel=(Mat_<float>(3,3)<<0,-.3f,0,-.3f,2.2f,-.3f,0,-.3f,0);filter2D(corrected,sharp,CV_32F,sharpenKernel,cv::Point(-1,-1),0,BORDER_REPLICATE);
    Mat residual(64,256,CV_32FC3);for(int y=0;y<64;y++)for(int x=0;x<256;x++)for(int c=0;c<3;c++)residual.at<Vec3f>(y,x)[c]=(std::clamp(std::floor(sharp.at<Vec3f>(y,x)[c]+.5f),0.f,255.f)-patch.at<Vec3b>(y,x)[c])*(alpha.at<uchar>(y,x)/255.f);
    Matx33d inverse(h.inv());std::array<Vec3d,4> corners={Vec3d(-1,-1,1),Vec3d(256,-1,1),Vec3d(256,64,1),Vec3d(-1,64,1)};
    double minx=INFINITY,miny=INFINITY,maxx=-INFINITY,maxy=-INFINITY;int sign=0;
    for(auto corner:corners){auto q=inverse*corner;if(!std::isfinite(q[2])||std::abs(q[2])<1e-8|| (sign&&((q[2]>0?1:-1)!=sign)))throw std::runtime_error("unbounded_eye_projection");sign=q[2]>0?1:-1;double x=q[0]/q[2],y=q[1]/q[2];minx=std::min(minx,x);miny=std::min(miny,y);maxx=std::max(maxx,x);maxy=std::max(maxy,y);}
    int x0=int(std::clamp(std::floor(minx)-2,0.,double(frame.cols))),y0=int(std::clamp(std::floor(miny)-2,0.,double(frame.rows))),x1=int(std::clamp(std::ceil(maxx)+3,0.,double(frame.cols))),y1=int(std::clamp(std::ceil(maxy)+3,0.,double(frame.rows)));
    if(x1<=x0||y1<=y0)return;
    Matx33d local=inverse;for(int i=0;i<3;i++){local(0,i)-=x0*inverse(2,i);local(1,i)-=y0*inverse(2,i);}
    Mat warped;warpPerspective(residual,warped,Mat(local),cv::Size(x1-x0,y1-y0),INTER_LINEAR,BORDER_CONSTANT,Scalar(0));
    for(int y=y0;y<y1;y++)for(int x=x0;x<x1;x++)for(int c=0;c<3;c++)frame.at<Vec3b>(y,x)[c]=uchar(std::floor(std::clamp(frame.at<Vec3b>(y,x)[c]+warped.at<Vec3f>(y-y0,x-x0)[c],0.f,255.f)+.5f));
}
struct State {bool tracking=false,visible=true;int visibilityCount=0;cv::Size size;Points previous;OneEuro filter;BoxState boxes;FeatureState features;};
}

@implementation LGTensorBuffer
- (instancetype)initWithPointer:(void *)pointer count:(NSUInteger)count {if((self=[super init])){_pointer=pointer;_count=count;}return self;}
@end

@implementation LGFramePipeline {
    id<LGModelProvider> _models;
    std::unique_ptr<State> _state;
    NSString *_lastStatus,*_lastReason;
    NSMutableDictionary<NSString *, NSNumber *> *_stageTimings;
    std::chrono::steady_clock::time_point _stageStart;
}
@synthesize profilingEnabled = _profilingEnabled;
- (NSDictionary<NSString *, NSNumber *> *)lastStageTimings {return _stageTimings ?: @{};}
- (void)markStage:(NSString *)name {
    if(!_profilingEnabled)return;
    auto now=std::chrono::steady_clock::now();
    _stageTimings[name]=@(std::chrono::duration<double,std::milli>(now-_stageStart).count());_stageStart=now;
}
- (instancetype)initWithModels:(id<LGModelProvider>)models {if((self=[super init])){_models=models;[self reset];}return self;}
- (void)reset {_state=std::make_unique<State>();_lastStatus=@"idle";_lastReason=@"";_stageTimings=nil;}
- (NSString *)lastStatus{return _lastStatus;}
- (NSString *)lastReason{return _lastReason;}
- (void)infer:(NSString*)key inputs:(std::initializer_list<std::pair<const char*,vector<float>*>>)inputs outputs:(std::initializer_list<std::pair<const char*,vector<float>*>>)outputs {
    NSMutableDictionary *in=[NSMutableDictionary dictionary],*out=[NSMutableDictionary dictionary];
    for(auto &item:inputs)in[@(item.first)]=[[LGTensorBuffer alloc] initWithPointer:item.second->data() count:item.second->size()];
    for(auto &item:outputs)out[@(item.first)]=[[LGTensorBuffer alloc] initWithPointer:item.second->data() count:item.second->size()];
    NSError *error=nil;if(![_models predictModel:key inputs:in outputs:out error:&error])throw std::runtime_error(error.localizedDescription.UTF8String ?: "model_prediction_failed");
    for(auto &item:outputs)for(float v:*item.second)if(!std::isfinite(v))throw std::runtime_error("non_finite_model_output");
}
- (Mat)process:(Mat)frame {
    auto &s=*_state;_lastStatus=@"bypass";_lastReason=@"";
    auto bypass=[&](NSString*reason){_lastReason=reason;return frame;};
    if(s.size!=frame.size()){_state=std::make_unique<State>();_state->size=frame.size();return [self process:frame];}
    cv::Rect crop;
    if(!s.tracking){
        auto input=letterbox(frame,368,208);auto feed=nchw(input.image);vector<float>bbox(4*13*23),coverage(13*23);
        [self infer:@"face" inputs:{{"input",&feed}} outputs:{{"output_bbox",&bbox},{"output_cov/Sigmoid",&coverage}}];
        vector<Rect2f>rects;vector<float>weights;
        for(int y=0;y<13;y++)for(int x=0;x<23;x++)if(coverage[y*23+x]>=.1f && rects.size()<200){
            int i=y*23+x;float x0=x*16+.5f-bbox[i]*35,y0=y*16+.5f-bbox[299+i]*35,x1=x*16+.5f+bbox[598+i]*35,y1=y*16+.5f+bbox[897+i]*35;
            if(x1>x0&&y1>y0){rects.emplace_back(x0,y0,x1-x0,y1-y0);weights.push_back(coverage[i]);}
        }
        vector<bool>visited(rects.size());vector<Rect2f>clusters;
        for(size_t seed=0;seed<rects.size();seed++)if(!visited[seed]){
            Vec4d sum(0,0,0,0);double total=0;
            for(size_t j=0;j<rects.size();j++)if(!visited[j]){
                float overlap=(rects[seed]&rects[j]).area(),distance=1-overlap/std::max(rects[seed].area()+rects[j].area()-overlap,1e-20f);
                if(j==seed||distance<.45f){visited[j]=true;auto r=rects[j];sum+=Vec4d(r.x,r.y,r.width,r.height)*weights[j];total+=weights[j];}
            }
            if(total>0){sum/=total;clusters.emplace_back(float(sum[0]),float(sum[1]),float(sum[2]),float(sum[3]));}
        }
        if(clusters.empty())return bypass(@"no_face");
        size_t selected=0;double best=s.boxes.hasPrevious?INFINITY:-INFINITY;
        auto t=input.transform;
        Point2f old((s.boxes.previous.x+s.boxes.previous.width*.5f)*t[0]+t[1],(s.boxes.previous.y+s.boxes.previous.height*.5f)*t[2]+t[3]);
        for(size_t i=0;i<clusters.size();i++){auto r=clusters[i];double score=s.boxes.hasPrevious?norm(old-Point2f(r.x+r.width*.5f,r.y+r.height*.5f)):r.area();if((s.boxes.hasPrevious&&score<best)||(!s.boxes.hasPrevious&&score>best)){best=score;selected=i;}}
        auto r=clusters[selected];r={(r.x-t[1])/t[0],(r.y-t[3])/t[2],r.width/t[0],r.height/t[2]};crop=square(s.boxes.smooth(r),.2f);
    }else{
        float x0=INFINITY,y0=INFINITY,x1=-INFINITY,y1=-INFINITY;
        for(auto p:s.previous){x0=std::min(x0,p.x);y0=std::min(y0,p.y);x1=std::max(x1,p.x);y1=std::max(y1,p.y);}
        float height=(y1-y0)*1.2f;crop=square(Rect2f(x0,std::max(y1-height,0.f),x1-x0,height),.3f);
    }
    [self markStage:@"tracking_or_detection"];
    if(crop.width<2||crop.width>8192){s.tracking=false;return bypass(@"invalid_face_box");}
    cv::Rect roi=crop&cv::Rect(0,0,frame.cols,frame.rows);if(roi.empty()){s.tracking=false;return bypass(@"face_outside_frame");}
    Mat face=Mat::zeros(crop.size(),CV_8UC3);frame(roi).copyTo(face(cv::Rect(roi.x-crop.x,roi.y-crop.y,roi.width,roi.height)));
    auto input=letterbox(face,160,160);Mat fp,gray;input.image.convertTo(fp,CV_32F);cvtColor(fp,gray,COLOR_BGR2GRAY);
    vector<float>feed(gray.ptr<float>(),gray.ptr<float>()+gray.total()),kpts(136),confidence(68);
    [self markStage:@"landmark_preprocess"];
    [self infer:@"landmarks" inputs:{{"input",&feed}} outputs:{{"kpts",&kpts},{"confidence",&confidence}}];
    [self markStage:@"landmark_model_and_head"];
    Points points;auto t=input.transform;double confidenceMean=0;
    for(int i=0;i<68;i++){points[i]={(kpts[i]-t[1])/t[0]+crop.x,(kpts[i+68]-t[3])/t[2]+crop.y};confidenceMean+=confidence[i];}
    confidenceMean=float(confidenceMean/68);s.filter.filter(points);s.tracking=confidenceMean>=.15f;if(s.tracking)s.previous=points;
    if(confidenceMean<=.15f)return bypass(@"landmark_confidence");
    Geometry g;
    try{g=geometry(points,frame.cols,frame.rows);}catch(const std::exception&){s.tracking=false;s.filter=OneEuro();s.boxes=BoxState();return bypass(@"invalid_face_geometry");}
    double eyeMean=0;float eyeMin=INFINITY;for(int i:eyeIndices){eyeMean+=confidence[i];eyeMin=std::min(eyeMin,confidence[i]);}
    bool visible=eyeMin>=.1f&&float(eyeMean/8)>=.2f&&std::abs(g.head[0])<=float(30*CV_PI/180)&&std::abs(g.head[1])<float(35*CV_PI/180)&&g.depth<1500;
    if(visible==s.visible)s.visibilityCount=std::min(s.visibilityCount+1,5);else if(s.visibilityCount<1){s.visible=visible;s.visibilityCount=5;}else s.visibilityCount--;
    float minY=INFINITY;for(auto p:points)minY=std::min(minY,p.y);
    if(!s.visible||int(minY)<0)return bypass(@"eyes_or_head_out_of_range");
    [self markStage:@"geometry_and_gating"];
    Mat patch=warpPatch(frame,g.homography);auto rgb=nchw(patch,true);vector<float>embeddings(1344),labels(12),target(2),decoded(3*64*256),lids(24);
    [self markStage:@"eye_warp"];
    [self infer:@"encoder" inputs:{{"input_image",&rgb}} outputs:{{"embeddings_flat",&embeddings},{"pseudo_labels_flat",&labels}}];
    [self markStage:@"encoder"];
    Vec2f goal=s.features.target(labels,points,g.head);target[0]=goal[0];target[1]=goal[1];
    if(std::max(std::abs(goal[0]),std::abs(goal[1]))>CV_PI)throw std::runtime_error("invalid_gaze_target");
    [self markStage:@"gaze_controls"];
    [self infer:@"decoder" inputs:{{"embeddings_flat",&embeddings},{"pseudo_labels_flat",&labels},{"gaze_por",&target}} outputs:{{"gaze_redirected_image",&decoded},{"gaze_landmarks",&lids}}];
    [self markStage:@"decoder"];
    try{restore(frame,patch,decoded,lids,points,g.homography);}catch(const std::exception&e){return bypass(@(e.what()));}
    [self markStage:@"composite"];
    _lastStatus=@"corrected";return frame;
}
- (BOOL)processPixelBuffer:(CVPixelBufferRef)input into:(CVPixelBufferRef)output error:(NSError**)error {
    if(CVPixelBufferGetPixelFormatType(input)!=kCVPixelFormatType_32BGRA||CVPixelBufferGetPixelFormatType(output)!=kCVPixelFormatType_32BGRA||CVPixelBufferGetWidth(input)!=CVPixelBufferGetWidth(output)||CVPixelBufferGetHeight(input)!=CVPixelBufferGetHeight(output)){
        _lastStatus=@"error";_lastReason=@"Expected matching BGRA pixel buffers";_stageTimings=nil;
        if(error)*error=[NSError errorWithDomain:@"LockedGaze" code:1 userInfo:@{NSLocalizedDescriptionKey:_lastReason}];return NO;
    }
    CVPixelBufferLockBaseAddress(input,kCVPixelBufferLock_ReadOnly);CVPixelBufferLockBaseAddress(output,0);
    BOOL success=YES;
    if(_profilingEnabled){_stageTimings=[NSMutableDictionary dictionary];_stageStart=std::chrono::steady_clock::now();}
    try{
        Mat bgra(int(CVPixelBufferGetHeight(input)),int(CVPixelBufferGetWidth(input)),CV_8UC4,CVPixelBufferGetBaseAddress(input),CVPixelBufferGetBytesPerRow(input));
        if(std::min(bgra.rows,bgra.cols)<16||std::max(bgra.rows,bgra.cols)>4096)throw std::runtime_error("unsupported_frame_dimensions");
        Mat bgr;cvtColor(bgra,bgr,COLOR_BGRA2BGR);[self markStage:@"input_conversion"];Mat result=[self process:bgr];
        Mat out(bgra.size(),CV_8UC4,CVPixelBufferGetBaseAddress(output),CVPixelBufferGetBytesPerRow(output));cvtColor(result,out,COLOR_BGR2BGRA);
        [self markStage:@"output_conversion"];
    }catch(const std::exception&e){
        success=NO;_lastStatus=@"error";_lastReason=@(e.what());
        if(error)*error=[NSError errorWithDomain:@"LockedGaze" code:2 userInfo:@{NSLocalizedDescriptionKey:_lastReason}];
    }
    CVPixelBufferUnlockBaseAddress(output,0);CVPixelBufferUnlockBaseAddress(input,kCVPixelBufferLock_ReadOnly);return success;
}
@end
