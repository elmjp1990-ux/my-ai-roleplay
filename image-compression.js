(function(){
  'use strict';
  const api={
    async compress(file,options={}){
      if(!file)throw new Error(options.readError||'無法讀取圖片，請換一張再試。');
      let image=null,sourceUrl='';
      try{
        if(options.decoder==='bitmap'){
          if(typeof createImageBitmap!=='function')throw new Error(options.decodeError||'目前裝置無法讀取圖片。');
          image=await createImageBitmap(file);
        }else{
          sourceUrl=URL.createObjectURL(file);
          image=await new Promise((resolve,reject)=>{
            const img=new Image();
            img.onload=()=>resolve(img);
            img.onerror=()=>reject(new Error(options.decodeError||'無法讀取這張圖片，請換一張再試。'));
            img.src=sourceUrl;
          });
        }
        const sourceWidth=Number(image.naturalWidth||image.width),sourceHeight=Number(image.naturalHeight||image.height);
        if(!sourceWidth||!sourceHeight)throw new Error(options.invalidDimensionsError||'圖片尺寸無效，請換一張再試。');
        const maxEdge=Number(options.maxEdge)||1440;
        const targetBytes=Number(options.targetBytes)||500*1024;
        const minScale=Number.isFinite(options.minScale)?options.minScale:.35;
        const scaleFactor=Number(options.scaleFactor)||.85;
        const formats=Array.isArray(options.formats)&&options.formats.length?options.formats:[{type:'image/webp',qualities:[.86,.78,.70,.62,.54]}];
        let scale=Math.min(1,maxEdge/Math.max(sourceWidth,sourceHeight));
        let bestBlob=null,bestWidth=0,bestHeight=0;
        while(scale>=minScale){
          const width=Math.max(1,Math.round(sourceWidth*scale)),height=Math.max(1,Math.round(sourceHeight*scale));
          const canvas=document.createElement('canvas');canvas.width=width;canvas.height=height;
          const ctx=canvas.getContext('2d',options.contextAttributes);
          if(!ctx)throw new Error(options.contextError||'目前瀏覽器無法壓縮圖片。');
          ctx.imageSmoothingEnabled=true;ctx.imageSmoothingQuality='high';
          for(const format of formats){
            if(format.background){
              ctx.fillStyle=format.background;
              ctx.fillRect(0,0,width,height);
            }else{
              ctx.clearRect(0,0,width,height);
            }
            ctx.drawImage(image,0,0,width,height);
            for(const quality of format.qualities||[undefined]){
              const blob=await new Promise((resolve,reject)=>{
                canvas.toBlob(value=>{
                  if(value)resolve(value);
                  else if(options.rejectOnEncodeFailure)reject(new Error(options.encodeError||'圖片壓縮失敗。'));
                  else resolve(null);
                },format.type,quality);
              });
              if(!blob||blob.type!==format.type)continue;
              if(!bestBlob||blob.size<bestBlob.size){bestBlob=blob;bestWidth=width;bestHeight=height;}
              if(blob.size<=targetBytes)return {blob,width,height,originalBytes:file.size,compressedBytes:blob.size,mimeType:blob.type};
            }
          }
          scale*=scaleFactor;
        }
        if(!bestBlob||bestBlob.size>(Number(options.maxOutputBytes)||1024*1024)){
          throw new Error(options.tooLargeError||'圖片壓縮後仍過大，請改選較小的圖片。');
        }
        return {blob:bestBlob,width:bestWidth,height:bestHeight,originalBytes:file.size,compressedBytes:bestBlob.size,mimeType:bestBlob.type};
      }finally{
        if(sourceUrl)URL.revokeObjectURL(sourceUrl);
        if(image&&typeof image.close==='function')image.close();
        else if(image&&'src'in image)image.src='';
      }
    }
  };
  window.PoyozzImageCompression=Object.freeze(api);
})();