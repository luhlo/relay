import assert from 'node:assert/strict';
import {createHandler} from './handler.mjs';

export async function runTests() {
  const user = '11111111-1111-4111-8111-111111111111';
  const other = '22222222-2222-4222-8222-222222222222';
  const session = '33333333-3333-4333-8333-333333333333';
  const encode = value => btoa(JSON.stringify(value)).replace(/=/g, '').replace(/\+/g, '-').replace(/\//g, '_');
  const token = extra => `${encode({alg:'test'})}.${encode({sub:user,session_id:session,role:'authenticated',exp:Date.now()/1000+600,...extra})}.signature`;
  let passed = 0;
  async function scenario(name, {method='POST',authorization=`Bearer ${token()}`,body={confirmation:'DELETE'},getUser,active=true,signOutFailure=false,deleteFailure=false,status=200,deleted=0,validate=true}={}) {
    const calls=[];
    const handler=createHandler({
      async getUser(value){calls.push(['auth',value]);return getUser === undefined ? {id:user}:getUser;},
      async isSessionActive(u,s){calls.push(['session',u,s]);return active;},
      async signOutEverywhere(value){calls.push(['signout',value]);if(signOutFailure)throw new Error('secret');},
      async deleteUser(id){calls.push(['delete',id]);if(deleteFailure)throw new Error('secret');},
    });
    const request=new Request('https://example.com/functions/v1/relay-delete-account',{
      method,headers:authorization?{Authorization:authorization}:{},
      ...(method==='GET'||method==='OPTIONS'?{}:{body:typeof body==='string'?body:JSON.stringify(body)}),
    });
    const result=await handler(request);
    assert.equal(result.status,status,name);
    assert.equal(calls.filter(c=>c[0]==='delete').length,deleted,name);
    if(status===200){
      assert.equal(JSON.stringify(await result.json()),JSON.stringify({deleted:true}),name);
      assert.deepEqual(calls.map(c=>c[0]),['auth','session','signout','delete'],name);
      assert.deepEqual(calls[1],['session',user,session],name);
      assert.deepEqual(calls[3],['delete',user],name);
    } else if(status!==204) {
      assert.equal((await result.text()).includes('secret'),false,name);
    }
    passed++;
  }
  await scenario('deletes only authenticated user',{deleted:1});
  await scenario('preflight does not authenticate/delete',{method:'OPTIONS',status:204});
  await scenario('GET cannot delete',{method:'GET',status:405});
  await scenario('missing bearer',{authorization:null,status:401});
  await scenario('bad bearer format',{authorization:'Basic x',status:401});
  await scenario('missing confirmation',{body:{},status:400});
  await scenario('wrong confirmation',{body:{confirmation:'delete'},status:400});
  await scenario('cannot select another user',{body:{confirmation:'DELETE',userId:other},status:400});
  await scenario('malformed JSON',{body:'invalid',status:400});
  await scenario('oversized request',{body:'x'.repeat(1025),status:413});
  await scenario('auth rejects token',{getUser:null,status:401});
  await scenario('server user mismatch',{getUser:{id:other},status:401});
  await scenario('missing session id',{authorization:`Bearer ${token({session_id:null})}`,status:401});
  await scenario('bad session id',{authorization:`Bearer ${token({session_id:'wrong'})}`,status:401});
  await scenario('expired token',{authorization:`Bearer ${token({exp:1})}`,status:401});
  await scenario('not a user role',{authorization:`Bearer ${token({role:'service_role'})}`,status:401});
  await scenario('logged out session',{active:false,status:401});
  await scenario('revocation failure prevents delete',{signOutFailure:true,status:500});
  await scenario('delete failure safely explained',{deleteFailure:true,status:500,deleted:1});
  return {passed};
}

if (import.meta.main) console.log(await runTests());
