//go:build !windows

package main

import "errors"

var errCredentialManagerUnsupported = errors.New("Windows Credential Manager is unavailable on this platform")

func credentialWrite(target, userName, secret string) error {
	return errCredentialManagerUnsupported
}

func credentialRead(target string) (string, error) {
	return "", errCredentialManagerUnsupported
}

func credentialDelete(target string) error {
	return errCredentialManagerUnsupported
}
