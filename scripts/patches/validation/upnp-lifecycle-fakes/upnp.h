#ifndef SWIFTVLC_UPNP_FAKE_UPNP_H
#define SWIFTVLC_UPNP_FAKE_UPNP_H

#ifdef __cplusplus
extern "C" {
#endif

typedef int UpnpClient_Handle;
typedef int Upnp_EventType;
typedef int (*Upnp_FunPtr)(Upnp_EventType, const void *, void *);

enum { UPNP_E_SUCCESS = 0 };

int UpnpInit2(const char *, unsigned short);
int UpnpFinish(void);
int UpnpRegisterClient(Upnp_FunPtr, const void *, UpnpClient_Handle *);
int UpnpUnRegisterClient(UpnpClient_Handle);
int UpnpSetMaxContentLength(size_t);
const char *UpnpGetErrorMessage(int);

typedef struct IXML_Element IXML_Element;
typedef struct IXML_Node IXML_Node;
typedef struct IXML_NodeList IXML_NodeList;

IXML_NodeList *ixmlElement_getElementsByTagName(IXML_Element *, const char *);
IXML_Node *ixmlNodeList_item(IXML_NodeList *, unsigned long);
void ixmlNodeList_free(IXML_NodeList *);
IXML_Node *ixmlNode_getFirstChild(IXML_Node *);
const char *ixmlNode_getNodeValue(IXML_Node *);
void ixmlRelaxParser(char);

#ifdef __cplusplus
}
#endif

#endif
