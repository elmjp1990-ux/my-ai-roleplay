import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

const source=fs.readFileSync("image-compression.js","utf8");

function createHarness({blobSize=1024}={}){
  const calls={contexts:[],clears:0,fills:[],draws:0,revoked:[],closed:0,qualities:[]};
  const document={
    createElement(name){
      assert.equal(name,"canvas");
      const context={
        imageSmoothingEnabled:false,imageSmoothingQuality:"",
        clearRect(){calls.clears++;},
        fillRect(){calls.fills.push({fillStyle:context.fillStyle});},
        drawImage(){calls.draws++;}
      };
      const canvas={
        width:0,height:0,
        getContext(type,attributes){calls.contexts.push({type,attributes});return context;},
        toBlob(callback,type,quality){calls.qualities.push({type,quality});callback({type,size:blobSize});}
      };
      return canvas;
    }
  };
  class MockImage{
    constructor(){this.naturalWidth=1000;this.naturalHeight=500;this.onload=null;this.onerror=null;this._src="";}
    set src(value){this._src=value;if(value&&this.onload)this.onload();}
    get src(){return this._src;}
  }
  const URL={
    createObjectURL(){return "blob:source";},
    revokeObjectURL(value){calls.revoked.push(value);}
  };
  const window={};
  const context={
    window,document,URL,Image:MockImage,
    createImageBitmap:async()=>({width:2000,height:1000,close(){calls.closed++;}})
  };
  vm.runInNewContext(source,context,{filename:"image-compression.js"});
  return {api:window.PoyozzImageCompression,calls};
}

test("shared core preserves transparent upload encoding and releases object URLs",async()=>{
  const {api,calls}=createHarness();
  const result=await api.compress({size:4096},{maxEdge:1440,targetBytes:500*1024,minScale:.35,
    formats:[{type:"image/webp",qualities:[.86,.78]},{type:"image/png",qualities:[1]}]});
  assert.equal(result.width,1000);
  assert.equal(result.height,500);
  assert.equal(result.mimeType,"image/webp");
  assert.equal(result.originalBytes,4096);
  assert.equal(calls.clears,1);
  assert.deepEqual(calls.revoked,["blob:source"]);
  assert.equal(calls.contexts[0].attributes,undefined);
  assert.deepEqual(calls.qualities,[{type:"image/webp",quality:.86}]);
});

test("shared core preserves memory-photo WebP, white background and 1200px preset",async()=>{
  const {api,calls}=createHarness();
  const result=await api.compress({size:8192},{decoder:"bitmap",maxEdge:1200,targetBytes:450*1024,
    minScale:.25,scaleFactor:.85,maxOutputBytes:1024*1024,contextAttributes:{alpha:false},
    formats:[{type:"image/webp",qualities:[.80,.72,.64,.56,.48],background:"#fff"}]});
  assert.equal(result.width,1200);
  assert.equal(result.height,600);
  assert.equal(result.mimeType,"image/webp");
  assert.equal(calls.contexts[0].attributes.alpha,false);
  assert.deepEqual(calls.fills,[{fillStyle:"#fff"}]);
  assert.equal(calls.clears,0);
  assert.equal(calls.closed,1);
});

test("shared core rejects output above the existing fallback budget",async()=>{
  const {api}=createHarness({blobSize:2*1024*1024});
  await assert.rejects(
    api.compress({size:8192},{decoder:"bitmap",maxEdge:1200,targetBytes:450*1024,minScale:.25,
      maxOutputBytes:1024*1024,formats:[{type:"image/webp",qualities:[.8],background:"#fff"}],
      tooLargeError:"仍超過 1 MB"}),
    /仍超過 1 MB/
  );
});
