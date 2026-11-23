import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
const CORS={ "Access-Control-Allow-Origin":"*", "Access-Control-Allow-Headers":"authorization, x-client-info, apikey, content-type", "Access-Control-Allow-Methods":"POST, OPTIONS", "Content-Type":"application/json" };
const json=(body:Record<string,unknown>,status=200)=>new Response(JSON.stringify(body),{status,headers:CORS});
const WMO:Record<number,string>={0:"晴天",1:"大致晴朗",2:"晴時多雲",3:"多雲",45:"霧",48:"霧",51:"毛毛雨",53:"毛毛雨",55:"毛毛雨",56:"凍毛毛雨",57:"凍毛毛雨",61:"小雨",63:"中雨",65:"大雨",66:"凍雨",67:"凍雨",71:"小雪",73:"降雪",75:"大雪",77:"雪粒",80:"短暫陣雨",81:"陣雨",82:"強陣雨",85:"陣雪",86:"強陣雪",95:"雷雨",96:"雷雨",99:"雷雨"};
const isRain=(text:string)=>/雨|陣雨|雷雨|毛毛雨|凍雨/.test(text);
async function weeklySync(admin:any,now:Date){
 const url="https://api.open-meteo.com/v1/forecast?latitude=25.0330&longitude=121.5654&hourly=temperature_2m,precipitation_probability,weather_code&forecast_days=7&timezone=Asia%2FTaipei";
 const response=await fetch(url,{headers:{"Accept":"application/json"},signal:AbortSignal.timeout(25000)});
 if(!response.ok)throw new Error("forecast_provider_http_"+response.status);
 const data=await response.json(),hours=data?.hourly;
 if(!Array.isArray(hours?.time)||!Array.isArray(hours?.temperature_2m)||!Array.isArray(hours?.precipitation_probability)||!Array.isArray(hours?.weather_code))throw new Error("forecast_provider_shape_invalid");
 const rows=hours.time.map((time:string,i:number)=>({city_key:"taipei",forecast_at:new Date(time+"+08:00").toISOString(),weather_code:Number(hours.weather_code[i]),weather_text:WMO[Number(hours.weather_code[i])]||"多雲",temperature_c:Number(hours.temperature_2m[i]),precipitation_probability:Math.max(0,Math.min(100,Number(hours.precipitation_probability[i])||0)),fetched_at:now.toISOString()})).filter((row:any)=>Number.isFinite(row.temperature_c)&&Number.isFinite(row.weather_code));
 if(rows.length<100)throw new Error("forecast_rows_insufficient");
 const {error}=await admin.from("encounter_city_weather_forecast_hourly").upsert(rows,{onConflict:"city_key,forecast_at"});
 if(error)throw new Error("forecast_cache_write_failed");
 const {error:deleteError}=await admin.from("encounter_city_weather_forecast_hourly").delete().eq("city_key","taipei").lt("forecast_at",now.toISOString());
 if(deleteError)throw new Error("forecast_cache_cleanup_failed");
 return {synced_rows:rows.length,forecast_start:rows[0]?.forecast_at,forecast_end:rows[rows.length-1]?.forecast_at,synced_at:now.toISOString()};
}
async function hourlyUpdate(admin:any,now:Date){
 const target=new Date(now);target.setMinutes(0,0,0);target.setHours(target.getHours()+1);
 const targetIso=target.toISOString();
 const {data,error}=await admin.from("encounter_city_weather_forecast_hourly").select("forecast_at,weather_text,temperature_c,precipitation_probability,fetched_at").eq("city_key","taipei").gte("forecast_at",targetIso).lt("forecast_at",new Date(target.getTime()+3600000).toISOString()).order("forecast_at").limit(1).maybeSingle();
 if(error)throw new Error("forecast_cache_read_failed");
 if(!data)return {status:"forecast_missing",target:targetIso};
 const text=String(data.weather_text||"多雲"),rain=isRain(text)||Number(data.precipitation_probability)>=60;
 const {error:writeError}=await admin.from("encounter_city_weather").upsert({city_key:"taipei",weather_text:text,temperature_c:data.temperature_c,precipitation_1h_mm:null,is_raining:rain,observed_at:targetIso,fetched_at:now.toISOString(),source:"open_meteo_weekly_forecast",precipitation_probability:data.precipitation_probability,forecast_for:data.forecast_at,forecast_synced_at:data.fetched_at,updated_at:now.toISOString()},{onConflict:"city_key"});
 if(writeError)throw new Error("current_weather_write_failed");
 return {status:"updated",weather_text:text,temperature_c:data.temperature_c,precipitation_probability:data.precipitation_probability,forecast_for:data.forecast_at};
}
Deno.serve(async(request)=>{
 if(request.method==="OPTIONS")return new Response("ok",{headers:CORS});
 if(request.method!=="POST")return json({error:"method_not_allowed"},405);
 const url=Deno.env.get("SUPABASE_URL")?.trim(),key=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")?.trim();
 if(!url||!key)return json({error:"server_not_configured"},503);
 if(request.headers.get("Authorization")!=="Bearer "+key)return json({error:"service_role_required"},401);
 let body:Record<string,unknown>={};try{const parsed=await request.json();if(parsed&&typeof parsed==="object"&&!Array.isArray(parsed))body=parsed;}catch{return json({error:"invalid_json"},400);}
 if(body.mode!=="scheduled")return json({error:"scheduled_mode_required"},400);
 const admin=createClient(url,key,{auth:{persistSession:false,autoRefreshToken:false}});
 const now=new Date();
 try{
  if(body.task==="weekly_sync")return json({task:"weekly_sync",...(await weeklySync(admin,now))});
  if(body.task==="hourly_update")return json({task:"hourly_update",...(await hourlyUpdate(admin,now))});
  return json({error:"unknown_weather_task"},400);
 }catch(error){return json({error:error instanceof Error?error.message:"weather_task_failed"},503);}
});
